import BatteryTraceCore
import Darwin
import Foundation

/// Per-app energy from the kernel's resource coalitions.
///
/// A coalition is the kernel's own group of an app with its helpers and XPC
/// services. It's what Activity Monitor and `powermetrics
/// --show-process-coalition` group by. Unlike `proc_pid_rusage`, reading a
/// coalition needs no privileges, so it covers root daemons and WindowServer
/// too. It also keeps counting a helper's usage after the helper exits.
///
/// Both calls are private:
/// - `proc_pidinfo(PROC_PIDCOALITIONINFO)`: flavor 20, `NO_CHECK_SAME_USER`
/// - `coalition_info_resource_usage()`: libsystem_kernel, looked up at run time
///
/// The struct layout comes from xnu `osfmk/mach/coalition.h`. Apple has only
/// appended to it (macOS 14 → 26/27), and the kernel copies `min(ours, its)`
/// bytes into a zeroed buffer, so a newer kernel never shifts these fields and
/// an older one leaves the missing ones at 0.
public final class CoalitionReader: DataSource {
    public let sourceName = "Coalitions"
    public private(set) var isAvailable = false
    public private(set) var diagnostics: [String] = []
    /// GPU and ANE energy per coalition: macOS 15 (xnu-11215) and later.
    public let hasGPUAndANEEnergy: Bool

    private typealias ResourceUsage = @convention(c) (UInt64, UnsafeMutableRawPointer, Int) -> Int32
    private let resourceUsage: ResourceUsage?
    private var buffer = [UInt64](repeating: 0, count: Field.count)
    private let machToNS: Double

    /// Field indices, in `UInt64`s, into `struct coalition_resource_usage`.
    private enum Field {
        static let tasksStarted = 0
        static let tasksExited = 1
        static let cpuTime = 3          // mach absolute time units
        static let interruptWakeups = 4
        static let idleWakeups = 5
        static let bytesRead = 6
        static let bytesWritten = 7
        static let gpuTime = 8          // nanoseconds
        static let energy = 11          // nanojoules (CLPC CPU energy model)
        static let aneEnergy = 39       // nanojoules, macOS 15+
        static let physFootprint = 40
        static let gpuEnergy = 41       // nanojoules, macOS 15+
        /// Up to `swapins` (xnu-12377). Asking for more is harmless.
        static let count = 45
    }

    private struct PIDCoalitionInfo {
        var resourceID: UInt64 = 0
        var jetsamID: UInt64 = 0
        var reserved: (UInt64, UInt64, UInt64) = (0, 0, 0)
    }

    private static let pidCoalitionInfoFlavor: Int32 = 20

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        machToNS = Double(timebase.numer) / Double(timebase.denom)
        hasGPUAndANEEnergy = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
        resourceUsage = PrivateSymbols.function("coalition_info_resource_usage", in: nil, as: ResourceUsage.self)
        guard resourceUsage != nil else {
            diagnostics.append("coalition_info_resource_usage not found")
            return
        }
        guard let mine = coalitionID(of: getpid()), mine != 0 else {
            diagnostics.append("PROC_PIDCOALITIONINFO refused")
            return
        }
        guard read(mine) != nil else {
            diagnostics.append("coalition_info_resource_usage refused")
            return
        }
        isAvailable = true
        diagnostics.append(hasGPUAndANEEnergy ? "CPU, GPU and ANE energy per coalition" : "CPU energy per coalition (no GPU/ANE before macOS 15)")
    }

    /// The resource coalition a process belongs to. Works for any process.
    public func coalitionID(of pid: Int32) -> UInt64? {
        var info = PIDCoalitionInfo()
        let size = Int32(MemoryLayout<PIDCoalitionInfo>.size)
        guard proc_pidinfo(pid, Self.pidCoalitionInfoFlavor, 0, &info, size) == size else { return nil }
        return info.resourceID
    }

    /// Cumulative usage for one coalition, or nil once it has been reaped.
    public func read(_ id: UInt64) -> CoalitionRecord? {
        guard let resourceUsage else { return nil }
        let status = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            return resourceUsage(id, bytes.baseAddress!, bytes.count)
        }
        guard status == 0 else { return nil }
        var counters = UsageCounters()
        counters.cpuEnergyNJ = buffer[Field.energy]
        counters.cpuTimeNS = UInt64(Double(buffer[Field.cpuTime]) * machToNS)
        counters.gpuTimeNS = buffer[Field.gpuTime]
        counters.interruptWakeups = buffer[Field.interruptWakeups]
        counters.idleWakeups = buffer[Field.idleWakeups]
        counters.diskReadBytes = buffer[Field.bytesRead]
        counters.diskWriteBytes = buffer[Field.bytesWritten]
        if hasGPUAndANEEnergy {
            counters.gpuEnergyNJ = buffer[Field.gpuEnergy]
            counters.aneEnergyNJ = buffer[Field.aneEnergy]
        }
        return CoalitionRecord(
            id: id, counters: counters,
            footprintBytes: hasGPUAndANEEnergy ? buffer[Field.physFootprint] : 0,
            tasksStarted: buffer[Field.tasksStarted], tasksExited: buffer[Field.tasksExited]
        )
    }
}

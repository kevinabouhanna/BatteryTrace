import BatteryTraceCore
import Darwin
import Foundation

/// Busy fraction per logical core, from `host_processor_info`. Public API.
public final class CPULoadSource: SnapshotSource {
    public let sourceName = "CPU load"
    public let isAvailable = true
    public var diagnostics: [String] { ["\(previous.count / Int(CPU_STATE_MAX)) logical cores"] }

    private var previous: [UInt32] = []

    public init() {}

    public func update(_ snapshot: inout SystemSnapshot) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        let stride = Int(CPU_STATE_MAX)
        let total = Int(cpuCount) * stride
        let ticks = UnsafeBufferPointer(start: UnsafeRawPointer(info).assumingMemoryBound(to: UInt32.self), count: total)
        defer { previous = Array(ticks) }
        guard previous.count == total else { return }

        var load = [Double](repeating: 0, count: Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            func delta(_ state: Int32) -> Double { Double(ticks[base + Int(state)] &- previous[base + Int(state)]) }
            let busy = delta(CPU_STATE_USER) + delta(CPU_STATE_SYSTEM) + delta(CPU_STATE_NICE)
            let all = busy + delta(CPU_STATE_IDLE)
            load[core] = all > 0 ? busy / all : 0
        }
        snapshot.cpuLoad = CPULoadSnapshot(perCore: load)
    }
}

/// Memory as Activity Monitor counts it, plus swap and pressure. Public API.
public final class MemorySource: SnapshotSource {
    public let sourceName = "Memory"
    public let isAvailable = true
    public let diagnostics: [String] = []

    private let pageSize = UInt64(getpagesize())
    private let total: UInt64 = {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        return size
    }()

    public init() {}

    public func update(_ snapshot: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return }

        var memory = MemorySnapshot()
        memory.totalBytes = total
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        memory.appBytes = (anonymous > purgeable ? anonymous - purgeable : 0) * pageSize
        memory.wiredBytes = UInt64(stats.wire_count) * pageSize
        memory.compressedBytes = UInt64(stats.compressor_page_count) * pageSize
        memory.usedBytes = memory.appBytes + memory.wiredBytes + memory.compressedBytes

        var swap = xsw_usage()
        var swapLength = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapLength, nil, 0) == 0 { memory.swapUsedBytes = swap.xsu_used }

        var level: Int32 = 0
        var levelLength = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelLength, nil, 0) == 0 {
            memory.pressure = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        }
        snapshot.memory = memory
    }
}

/// Thermal state and Low Power Mode, from `ProcessInfo`. Public API.
public final class ThermalSource: SnapshotSource {
    public let sourceName = "Thermal"
    public let isAvailable = true
    public let diagnostics: [String] = []

    public init() {}

    public func update(_ snapshot: inout SystemSnapshot) {
        let info = ProcessInfo.processInfo
        snapshot.thermal = switch info.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        snapshot.lowPowerMode = info.isLowPowerModeEnabled
    }
}

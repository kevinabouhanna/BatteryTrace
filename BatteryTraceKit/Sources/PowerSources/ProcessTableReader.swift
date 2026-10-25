import BatteryTraceCore
import Darwin
import Foundation

/// The live process table, with per-process energy where the kernel allows.
///
/// `proc_pid_rusage` is public but `CHECK_SAME_USER`: without root it refuses
/// other users' processes (WindowServer, root daemons). Those still appear,
/// with their coalition and path, but `counters == nil`. Their energy reaches
/// their app through the coalition instead.
///
/// Steady state, per tick, per PID: one coalition-ID call, plus
/// `proc_pid_rusage` for processes that answered it before. Path, name and
/// parent are read once, when a PID (or its coalition) is new.
public final class ProcessTableReader: DataSource {
    public let sourceName = "Process table"
    public private(set) var isAvailable = false
    public private(set) var diagnostics: [String] = []

    private var pids = [Int32](repeating: 0, count: 2048)
    private let flavor: Int32
    private let machToNS: Double
    private let coalitions: CoalitionReader?
    private var pathBuffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))

    private struct Identity {
        var coalitionID: UInt64
        var name: String
        var path: String?
        var parentPID: Int32
        var uid: UInt32
        /// `ri_proc_start_abstime` when readable: tells a reused PID apart.
        var startTime: UInt64
        var readable: Bool
        var lastSeen: UInt32
    }

    private var identities: [Int32: Identity] = [:]
    private var generation: UInt32 = 0
    /// Processes that refused `proc_pid_rusage` are asked again this often,
    /// in case they changed user.
    private let recheckEvery: UInt32 = 64

    public init(coalitions: CoalitionReader?) {
        self.coalitions = coalitions
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        machToNS = Double(timebase.numer) / Double(timebase.denom)

        // V6 adds `ri_energy_nj`. Fall back to V4's `ri_billed_energy` on
        // systems that refuse V6.
        var probe = rusage_info_v6()
        if Self.rusage(getpid(), RUSAGE_INFO_V6, &probe) {
            flavor = RUSAGE_INFO_V6
            diagnostics.append("proc_pid_rusage V6 (ri_energy_nj)")
        } else {
            flavor = RUSAGE_INFO_V4
            diagnostics.append("proc_pid_rusage V4 (ri_billed_energy)")
        }
        isAvailable = proc_listallpids(nil, 0) > 0
    }

    /// Replaces `records` with the live process table, without counters.
    /// Keeps its capacity. Known processes cost no system call beyond the
    /// listing; other users' processes are re-checked for a changed
    /// coalition (a reused PID) every few ticks.
    public func list(into records: inout [ProcessRecord]) {
        records.removeAll(keepingCapacity: true)
        var count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        if count >= pids.count {
            pids = [Int32](repeating: 0, count: count * 2)
            count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        }
        guard count > 0 else { return }
        generation &+= 1

        for i in 0..<min(count, pids.count) {
            let pid = pids[i]
            var identity: Identity
            if var known = identities[pid] {
                if !known.readable, (UInt32(bitPattern: pid) &+ generation) % 8 == 0 {
                    let coalitionID = coalitions?.coalitionID(of: pid) ?? 0
                    if coalitionID != known.coalitionID {
                        guard let fresh = resolve(pid: pid, coalitionID: coalitionID) else { continue }
                        known = fresh
                    }
                }
                identity = known
            } else {
                guard let fresh = resolve(pid: pid, coalitionID: coalitions?.coalitionID(of: pid) ?? 0) else { continue }
                identity = fresh
            }
            identity.lastSeen = generation
            identities[pid] = identity
            records.append(ProcessRecord(
                pid: pid, parentPID: identity.parentPID, uid: identity.uid, name: identity.name, path: identity.path,
                coalitionID: identity.coalitionID, startTime: identity.startTime
            ))
        }

        // Forget processes that are gone, now and then rather than every tick.
        if identities.count > records.count + 256 {
            let current = generation
            identities = identities.filter { $0.value.lastSeen == current }
        }
    }

    /// Fills in counters for the records `shouldRead` picks. Other users'
    /// processes are skipped: `proc_pid_rusage` refuses them, and they are
    /// asked again only now and then.
    public func readCounters(into records: inout [ProcessRecord], where shouldRead: (ProcessRecord) -> Bool) {
        var usage = rusage_info_v6()
        let recheck = generation % recheckEvery == 0
        for i in records.indices where shouldRead(records[i]) {
            let pid = records[i].pid
            guard var identity = identities[pid], identity.readable || recheck else { continue }
            guard Self.rusage(pid, flavor, &usage) else {
                identity.readable = false
                identities[pid] = identity
                continue
            }
            if identity.startTime != 0, usage.ri_proc_start_abstime != identity.startTime,
               let fresh = resolve(pid: pid, coalitionID: coalitions?.coalitionID(of: pid) ?? 0) {
                identity = fresh // same PID, different process
                records[i].name = identity.name
                records[i].path = identity.path
                records[i].coalitionID = identity.coalitionID
                records[i].parentPID = identity.parentPID
            }
            identity.readable = true
            identity.startTime = usage.ri_proc_start_abstime
            identities[pid] = identity
            records[i].startTime = identity.startTime
            records[i].footprintBytes = usage.ri_phys_footprint
            records[i].counters = UsageCounters(
                cpuEnergyNJ: flavor == RUSAGE_INFO_V6 ? usage.ri_energy_nj : usage.ri_billed_energy,
                cpuTimeNS: UInt64(Double(usage.ri_user_time &+ usage.ri_system_time) * machToNS),
                interruptWakeups: usage.ri_interrupt_wkups,
                idleWakeups: usage.ri_pkg_idle_wkups,
                diskReadBytes: usage.ri_diskio_bytesread,
                diskWriteBytes: usage.ri_diskio_byteswritten
            )
        }
    }

    /// The whole table with every readable process's counters.
    public func read(into records: inout [ProcessRecord]) {
        list(into: &records)
        readCounters(into: &records) { _ in true }
    }

    private func resolve(pid: Int32, coalitionID: UInt64) -> Identity? {
        var bsd = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, size) == size else { return nil }
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = length > 0 ? pathBuffer.withUnsafeBufferPointer { buffer in
            String(decoding: UnsafeRawBufferPointer(buffer).prefix(Int(length)), as: UTF8.self)
        } : nil
        let shortName = withUnsafeBytes(of: bsd.pbsi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let name = path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? shortName
        return Identity(coalitionID: coalitionID, name: name.isEmpty ? (pid == 0 ? "kernel_task" : "pid \(pid)") : name,
                        path: path, parentPID: Int32(bitPattern: bsd.pbsi_ppid), uid: bsd.pbsi_uid,
                        startTime: 0, readable: true, lastSeen: generation)
    }

    private static func rusage(_ pid: Int32, _ flavor: Int32, _ info: inout rusage_info_v6) -> Bool {
        withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, flavor, $0) == 0 }
        }
    }
}

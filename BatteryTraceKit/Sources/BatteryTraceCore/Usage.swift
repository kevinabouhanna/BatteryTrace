/// Cumulative counters the kernel keeps for a coalition or a process.
///
/// Every field only ever grows, so two readings give the usage in between,
/// however far apart they are. Sampling slowly loses time resolution, not
/// energy.
public struct UsageCounters: Sendable, Hashable, Codable {
    /// The kernel's per-thread CPU energy model (CLPC), in nanojoules.
    public var cpuEnergyNJ: UInt64 = 0
    /// GPU energy the driver bills to this coalition, in nanojoules. macOS 15+.
    public var gpuEnergyNJ: UInt64 = 0
    /// Neural Engine energy, in nanojoules. macOS 15+.
    public var aneEnergyNJ: UInt64 = 0
    public var cpuTimeNS: UInt64 = 0
    public var gpuTimeNS: UInt64 = 0
    public var interruptWakeups: UInt64 = 0
    public var idleWakeups: UInt64 = 0
    public var diskReadBytes: UInt64 = 0
    public var diskWriteBytes: UInt64 = 0

    public init() {}

    public init(cpuEnergyNJ: UInt64 = 0, gpuEnergyNJ: UInt64 = 0, aneEnergyNJ: UInt64 = 0,
                cpuTimeNS: UInt64 = 0, gpuTimeNS: UInt64 = 0,
                interruptWakeups: UInt64 = 0, idleWakeups: UInt64 = 0,
                diskReadBytes: UInt64 = 0, diskWriteBytes: UInt64 = 0) {
        self.cpuEnergyNJ = cpuEnergyNJ
        self.gpuEnergyNJ = gpuEnergyNJ
        self.aneEnergyNJ = aneEnergyNJ
        self.cpuTimeNS = cpuTimeNS
        self.gpuTimeNS = gpuTimeNS
        self.interruptWakeups = interruptWakeups
        self.idleWakeups = idleWakeups
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
    }

    public static let zero = UsageCounters()

    /// What happened between `earlier` and `self`, or nil if any counter went
    /// backwards: the PID or coalition ID was reused, so the two readings are
    /// of different things.
    public func delta(since earlier: UsageCounters) -> UsageCounters? {
        guard cpuEnergyNJ >= earlier.cpuEnergyNJ, gpuEnergyNJ >= earlier.gpuEnergyNJ,
              aneEnergyNJ >= earlier.aneEnergyNJ, cpuTimeNS >= earlier.cpuTimeNS,
              gpuTimeNS >= earlier.gpuTimeNS, interruptWakeups >= earlier.interruptWakeups,
              idleWakeups >= earlier.idleWakeups, diskReadBytes >= earlier.diskReadBytes,
              diskWriteBytes >= earlier.diskWriteBytes
        else { return nil }
        return UsageCounters(
            cpuEnergyNJ: cpuEnergyNJ - earlier.cpuEnergyNJ,
            gpuEnergyNJ: gpuEnergyNJ - earlier.gpuEnergyNJ,
            aneEnergyNJ: aneEnergyNJ - earlier.aneEnergyNJ,
            cpuTimeNS: cpuTimeNS - earlier.cpuTimeNS,
            gpuTimeNS: gpuTimeNS - earlier.gpuTimeNS,
            interruptWakeups: interruptWakeups - earlier.interruptWakeups,
            idleWakeups: idleWakeups - earlier.idleWakeups,
            diskReadBytes: diskReadBytes - earlier.diskReadBytes,
            diskWriteBytes: diskWriteBytes - earlier.diskWriteBytes
        )
    }

    public static func + (a: UsageCounters, b: UsageCounters) -> UsageCounters {
        UsageCounters(
            cpuEnergyNJ: a.cpuEnergyNJ &+ b.cpuEnergyNJ,
            gpuEnergyNJ: a.gpuEnergyNJ &+ b.gpuEnergyNJ,
            aneEnergyNJ: a.aneEnergyNJ &+ b.aneEnergyNJ,
            cpuTimeNS: a.cpuTimeNS &+ b.cpuTimeNS,
            gpuTimeNS: a.gpuTimeNS &+ b.gpuTimeNS,
            interruptWakeups: a.interruptWakeups &+ b.interruptWakeups,
            idleWakeups: a.idleWakeups &+ b.idleWakeups,
            diskReadBytes: a.diskReadBytes &+ b.diskReadBytes,
            diskWriteBytes: a.diskWriteBytes &+ b.diskWriteBytes
        )
    }

    public static func += (a: inout UsageCounters, b: UsageCounters) { a = a + b }

    /// The counter that splits a component of the given kind.
    public func value(for split: AppSplit) -> UInt64 {
        switch split {
        case .cpu: cpuEnergyNJ
        case .gpu: gpuEnergyNJ
        case .ane: aneEnergyNJ
        case .none: 0
        }
    }

    public var isZero: Bool { self == .zero }
}

/// One live process, as the process table reports it.
public struct ProcessRecord: Sendable, Hashable {
    public var pid: Int32
    public var parentPID: Int32
    public var uid: UInt32
    /// The short command name, or the executable's file name when readable.
    public var name: String
    /// The executable's full path. Nil when the kernel would not say.
    public var path: String?
    /// The process's resource coalition. 0 when unknown.
    public var coalitionID: UInt64
    /// `ri_proc_start_abstime`: tells a reused PID apart. 0 when unreadable.
    public var startTime: UInt64
    /// Cumulative counters. Nil for other users' processes, which
    /// `proc_pid_rusage` refuses without root.
    public var counters: UsageCounters?
    public var footprintBytes: UInt64?

    public init(pid: Int32, parentPID: Int32 = 0, uid: UInt32 = 0, name: String, path: String? = nil,
                coalitionID: UInt64 = 0, startTime: UInt64 = 0, counters: UsageCounters? = nil,
                footprintBytes: UInt64? = nil) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.name = name
        self.path = path
        self.coalitionID = coalitionID
        self.startTime = startTime
        self.counters = counters
        self.footprintBytes = footprintBytes
    }
}

/// One resource coalition: the kernel's own grouping of an app with its
/// helpers and XPC services.
public struct CoalitionRecord: Sendable, Hashable {
    public var id: UInt64
    public var counters: UsageCounters
    public var footprintBytes: UInt64
    public var tasksStarted: UInt64
    public var tasksExited: UInt64

    public init(id: UInt64, counters: UsageCounters, footprintBytes: UInt64 = 0, tasksStarted: UInt64 = 0, tasksExited: UInt64 = 0) {
        self.id = id
        self.counters = counters
        self.footprintBytes = footprintBytes
        self.tasksStarted = tasksStarted
        self.tasksExited = tasksExited
    }

    /// The kernel's own coalition, home of `kernel_task`.
    public static let kernelCoalitionID: UInt64 = 1
}

import BatteryTraceCore
import Darwin
import Foundation
import HelperProtocol
import PowerSources

/// The unprivileged provider, plus the optional root helper when it is
/// installed and switched on:
///
/// - **CPU** becomes Apple's `powermetrics` figure instead of PMP's cluster
///   counters. The helper takes a `powermetrics` sample at the same moment
///   as the other readings, so the sample covers the same interval.
/// - **Processes** that `proc_pid_rusage` refused (other users') get their
///   counters from the helper, which runs as root.
///
/// Any interval the helper can't cover keeps the unprivileged figures: not
/// installed, a different version, too slow, or the first interval after it
/// starts. Switching it on or off, or losing it, never leaves a gap or counts
/// anything twice.
public final class PrivilegedPowerMetrics: PowerMetricsProvider {
    public let base: UnprivilegedPowerMetrics
    public let helper: PrivilegedHelperClient

    public var providerName: String {
        cpuFromPowermetrics ? "Privileged helper (powermetrics CPU, root rusage) + \(base.providerName)" : base.providerName
    }
    public var isAvailable: Bool { base.isAvailable }
    public var dataSources: [any DataSource] { base.dataSources + [helper] }

    /// Use the helper when it is installed. Off, nothing here touches `sudo`.
    public var usesHelper = false {
        didSet {
            guard usesHelper != oldValue else { return }
            helper.stop()
            nextAttempt = nil
            rootBaselines.removeAll()
        }
    }

    /// Whether the last interval's CPU came from `powermetrics`.
    public private(set) var cpuFromPowermetrics = false

    /// How far `powermetrics`' sample may differ in length from the interval
    /// and still be taken as covering it.
    static let coverageTolerance = (seconds: 0.25, fraction: 0.05)
    /// After the helper fails, how long before starting it again.
    static let retryAfterNS: UInt64 = 300 * 1_000_000_000
    /// Long enough for a `powermetrics` that has just started: the helper
    /// waits 1.5 s for it to warm up, then up to 2 s for a sample, twice.
    static let replyTimeout: Double = 6

    private var nextAttempt: UInt64?
    private var rootBaselines: [Int32: (start: UInt64, counters: UsageCounters)] = [:]
    private var currentRoot: [Int32: (start: UInt64, counters: UsageCounters)] = [:]
    private let machToNS: Double

    public init(base: UnprivilegedPowerMetrics, helper: PrivilegedHelperClient = PrivilegedHelperClient()) {
        self.base = base
        self.helper = helper
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        machToNS = Double(timebase.numer) / Double(timebase.denom)
    }

    public func resetBaseline() {
        base.resetBaseline()
        rootBaselines.removeAll()
    }

    public func nextSample(nowUptimeNS: UInt64) -> PowerMetricsSample? {
        cpuFromPowermetrics = false
        guard usesHelper, ensureHelper(now: nowUptimeNS) else {
            // A baseline from before the helper went away would make one
            // long delta when it comes back.
            rootBaselines.removeAll()
            return base.nextSample(nowUptimeNS: nowUptimeNS)
        }
        // Ask first, then read everything else while `powermetrics` samples:
        // the two readings start within a millisecond of each other.
        let powerRequest = helper.send { .power(seq: $0) }
        let sample = base.nextSample(nowUptimeNS: nowUptimeNS)
        var reading: PowerReading?
        if let powerRequest, case .power(_, let answer)? = helper.receive(powerRequest, timeout: Self.replyTimeout) {
            reading = answer
        }
        guard var sample else { return nil }

        if let reading, Self.covers(reading, interval: sample.durationSeconds) {
            Self.replaceCPU(in: &sample, joules: reading.cpuMillijoules / 1000)
            sample.cpuFromPowermetrics = true
            cpuFromPowermetrics = true
        }
        if helper.isAvailable { addRootCounters(to: &sample) }
        if !helper.isAvailable { nextAttempt = nowUptimeNS &+ Self.retryAfterNS }
        return sample
    }

    /// Starts the helper if it isn't running and it's time to try.
    private func ensureHelper(now: UInt64) -> Bool {
        if helper.isAvailable { return true }
        if let nextAttempt, now < nextAttempt { return false }
        nextAttempt = now &+ Self.retryAfterNS
        guard PrivilegedHelperClient.isInstalled, helper.start() else { return false }
        return true
    }

    /// Whether a sample covers the interval: the same length, give or take.
    /// The first sample after the helper starts covers its start-up instead,
    /// and is turned down here.
    static func covers(_ reading: PowerReading, interval: Double) -> Bool {
        let slack = max(coverageTolerance.seconds, interval * coverageTolerance.fraction)
        return interval > 0 && abs(reading.elapsedSeconds - interval) <= slack
    }

    static func replaceCPU(in sample: inout PowerMetricsSample, joules: Double) {
        let cpu = ComponentEnergy(id: .cpu, joules: joules, provenance: .measured)
        if let index = sample.components.firstIndex(where: { $0.id == .cpu }) {
            sample.components[index] = cpu
        } else {
            sample.components.append(cpu)
        }
    }

    /// Counters for the processes the unprivileged reader couldn't read, in
    /// coalitions that used energy this interval: the same ones it reads for
    /// its own processes. Others keep their baseline until they do.
    private func addRootCounters(to sample: inout PowerMetricsSample) {
        let anyCoalitions = !sample.coalitions.isEmpty || sample.processes.contains { $0.coalitionID != 0 }
        var wanted: [Int32] = []
        for record in sample.processes where record.counters == nil {
            if !anyCoalitions || sample.coalitions[record.coalitionID] != nil { wanted.append(record.pid) }
        }
        currentRoot.removeAll(keepingCapacity: true)
        if !wanted.isEmpty,
           let request = helper.send({ .rusage(seq: $0, pids: Array(wanted.prefix(HelperProtocol.maxPIDsPerRequest))) }),
           case .rusage(_, let records)? = helper.receive(request, timeout: Self.replyTimeout) {
            var byPID: [Int32: RootRusage] = [:]
            byPID.reserveCapacity(records.count)
            for record in records { byPID[record.pid] = record }
            for index in sample.processes.indices where sample.processes[index].counters == nil {
                let pid = sample.processes[index].pid
                guard let usage = byPID[pid] else { continue }
                let counters = UsageCounters(
                    cpuEnergyNJ: usage.energyNJ,
                    cpuTimeNS: UInt64(Double(usage.userTime &+ usage.systemTime) * machToNS),
                    interruptWakeups: usage.interruptWakeups,
                    idleWakeups: usage.idleWakeups,
                    diskReadBytes: usage.diskReadBytes,
                    diskWriteBytes: usage.diskWriteBytes
                )
                sample.processes[index].counters = counters
                sample.processes[index].footprintBytes = usage.footprintBytes
                if let previous = rootBaselines[pid], previous.start == usage.startAbstime,
                   let delta = counters.delta(since: previous.counters) {
                    sample.processDeltas[pid] = delta
                }
                currentRoot[pid] = (usage.startAbstime, counters)
            }
        }
        // Keep the baselines of processes that are still alive but weren't
        // asked about this time.
        if !rootBaselines.isEmpty {
            var alive = Set<Int32>()
            alive.reserveCapacity(sample.processes.count)
            for record in sample.processes { alive.insert(record.pid) }
            for (pid, baseline) in rootBaselines where currentRoot[pid] == nil && alive.contains(pid) {
                currentRoot[pid] = baseline
            }
        }
        swap(&rootBaselines, &currentRoot)
    }
}

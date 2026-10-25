import BatteryTraceCore
import PowerSources

/// The MVP's `PowerMetricsProvider`: IOReport for components, coalitions
/// for apps, `proc_pid_rusage` for their processes. No root anywhere.
///
/// Turns the kernel's cumulative counters into per-interval deltas. A counter
/// that goes backwards means a reused PID or coalition ID; that interval is
/// skipped for it rather than reported as a huge negative.
///
/// Because every counter is cumulative, a read can be skipped without losing
/// energy: the next read's delta covers both intervals. That is how a tick
/// stays cheap. Quiet coalitions are read every fourth tick, and processes
/// only when their coalition used energy.
public final class UnprivilegedPowerMetrics: PowerMetricsProvider {
    public let providerName = "Unprivileged (IOReport + coalitions + rusage)"
    public var isAvailable: Bool { processes.isAvailable }
    public var dataSources: [any DataSource] {
        var all: [any DataSource] = componentSources
        all.append(processes)
        if let coalitions { all.append(coalitions) }
        if let gpuClients { all.append(gpuClients) }
        return all
    }

    public let componentSources: [any ComponentSource]
    public let coalitions: CoalitionReader?
    private let processes: ProcessTableReader
    /// Only on macOS 14, whose coalitions carry no GPU energy.
    private let gpuClients: GPUClientReader?

    /// CPU time per stage of the last `nextSample`, for `bttrace cost`.
    public private(set) var lastTimings: [(stage: String, ns: UInt64)] = []

    /// Coalitions read on the last tick, out of how many were wanted.
    public private(set) var lastCoalitionReads = (read: 0, wanted: 0)

    /// Whether app GPU weights are energy (macOS 15+) or GPU time (fallback).
    public var gpuWeightsAreEnergy: Bool { coalitions?.hasGPUAndANEEnergy ?? false }

    private var lastUptimeNS: UInt64?
    private var tick: UInt64 = 0
    private var records: [ProcessRecord] = []
    private var lastCoalitions: [UInt64: UsageCounters] = [:]
    private var currentCoalitions: [UInt64: UsageCounters] = [:]
    private var wantedCoalitions = Set<UInt64>()
    /// Consecutive reads below `quietEnergyNJ`, per coalition.
    private var quietReads: [UInt64: UInt8] = [:]
    /// 1 mJ: under 0.2 mW over a 5 s tick.
    private static let quietEnergyNJ: UInt64 = 1_000_000
    private var lastProcesses: [Int32: (start: UInt64, counters: UsageCounters)] = [:]
    private var currentProcesses: [Int32: (start: UInt64, counters: UsageCounters)] = [:]
    private var lastGPUTime: [Int32: UInt64] = [:]
    private var gpuTime: [Int32: UInt64] = [:]
    // Handed out in each sample and cleared, keeping capacity, on the next
    // tick. Once the pipeline drops the sample the storage is ours again, so
    // the steady state allocates no new dictionaries.
    private var coalitionDeltas: [UInt64: UsageCounters] = [:]
    private var processDeltas: [Int32: UsageCounters] = [:]

    public init(componentSources: [any ComponentSource], coalitions: CoalitionReader?, processes: ProcessTableReader, gpuClients: GPUClientReader?) {
        self.componentSources = componentSources
        self.coalitions = coalitions
        self.processes = processes
        self.gpuClients = gpuClients
    }

    /// The standard set of sources for this Mac.
    public static func standard(display: DisplayBacklightSource?) -> UnprivilegedPowerMetrics {
        let coalitionReader = CoalitionReader()
        let coalitions = coalitionReader.isAvailable ? coalitionReader : nil
        var components: [any ComponentSource] = [IOReportComponentSource()]
        if let display, display.isAvailable { components.append(display) }
        let needsGPUClients = !(coalitions?.hasGPUAndANEEnergy ?? false)
        return UnprivilegedPowerMetrics(
            componentSources: components,
            coalitions: coalitions,
            processes: ProcessTableReader(coalitions: coalitions),
            gpuClients: needsGPUClients ? GPUClientReader() : nil
        )
    }

    public func resetBaseline() {
        lastUptimeNS = nil
        lastCoalitions.removeAll()
        lastProcesses.removeAll()
        lastGPUTime.removeAll()
        quietReads.removeAll()
        for source in componentSources { source.resetBaseline() }
    }

    public func nextSample(nowUptimeNS: UInt64) -> PowerMetricsSample? {
        let interval = lastUptimeNS.map { Double(nowUptimeNS &- $0) / 1e9 } ?? 0
        defer { lastUptimeNS = nowUptimeNS }
        tick &+= 1

        var mark = Clock.threadCPUTimeNS()
        lastTimings.removeAll(keepingCapacity: true)
        func lap(_ stage: String) {
            let now = Clock.threadCPUTimeNS()
            lastTimings.append((stage, now &- mark))
            mark = now
        }

        var components: [ComponentEnergy] = []
        for source in componentSources where source.isAvailable {
            source.readComponents(intervalSeconds: interval, into: &components)
            lap(source.sourceName)
        }

        processes.list(into: &records)
        lap("process table")

        coalitionDeltas.removeAll(keepingCapacity: true)
        if let coalitions {
            readCoalitions(coalitions)
            lap("coalitions")
        }

        // Per-process counters only where there's something to split: in a
        // coalition that used energy this interval. The rest keep their
        // baseline for the interval in which they next do.
        if coalitions != nil {
            processes.readCounters(into: &records) { coalitionDeltas[$0.coalitionID] != nil }
        } else {
            processes.readCounters(into: &records) { _ in true }
        }
        lap("process counters")

        processDeltas.removeAll(keepingCapacity: true)
        currentProcesses.removeAll(keepingCapacity: true)
        for record in records {
            guard let counters = record.counters else {
                if let previous = lastProcesses[record.pid], previous.start == record.startTime || record.startTime == 0 {
                    currentProcesses[record.pid] = previous
                }
                continue
            }
            if let previous = lastProcesses[record.pid], previous.start == record.startTime,
               let delta = counters.delta(since: previous.counters) {
                processDeltas[record.pid] = delta
            }
            currentProcesses[record.pid] = (record.startTime, counters)
        }
        swap(&lastProcesses, &currentProcesses)
        lap("process deltas")

        if let gpuClients {
            addGPUTime(from: gpuClients)
            lap("GPU clients")
        }

        guard interval > 0 else { return nil }
        return PowerMetricsSample(endUptimeNS: nowUptimeNS, durationSeconds: interval, components: components,
                                  coalitions: coalitionDeltas, processes: records, processDeltas: processDeltas)
    }

    /// Every live coalition, plus last tick's, so a coalition whose last
    /// process just exited still reports its final interval. Quiet ones are
    /// read every fourth tick; a skipped read only folds their trickle into a
    /// later interval.
    private func readCoalitions(_ coalitions: CoalitionReader) {
        wantedCoalitions.removeAll(keepingCapacity: true)
        for record in records where record.coalitionID != 0 { wantedCoalitions.insert(record.coalitionID) }
        for id in lastCoalitions.keys { wantedCoalitions.insert(id) }
        currentCoalitions.removeAll(keepingCapacity: true)
        var reads = 0
        defer { lastCoalitionReads = (reads, wantedCoalitions.count) }
        for id in wantedCoalitions {
            if let previous = lastCoalitions[id], (quietReads[id] ?? 0) >= 2, (tick &+ id) % 4 != 0 {
                currentCoalitions[id] = previous
                continue
            }
            reads += 1
            guard let record = coalitions.read(id) else {
                quietReads[id] = nil
                continue
            }
            currentCoalitions[id] = record.counters
            guard let previous = lastCoalitions[id], let delta = record.counters.delta(since: previous) else { continue }
            let energy = delta.cpuEnergyNJ &+ delta.gpuEnergyNJ &+ delta.aneEnergyNJ
            quietReads[id] = energy < Self.quietEnergyNJ ? min(255, (quietReads[id] ?? 0) &+ 1) : 0
            if !delta.isZero { coalitionDeltas[id] = delta }
        }
        swap(&lastCoalitions, &currentCoalitions)
        if quietReads.count > lastCoalitions.count + 256 {
            quietReads = quietReads.filter { lastCoalitions[$0.key] != nil }
        }
    }

    /// macOS 14: weight GPU by driver time. The value goes in `gpuEnergyNJ`
    /// because it only ever serves as a proportional weight.
    private func addGPUTime(from reader: GPUClientReader) {
        reader.read(into: &gpuTime)
        defer { swap(&lastGPUTime, &gpuTime) }
        guard !lastGPUTime.isEmpty else { return }
        let coalitionOf = Dictionary(records.map { ($0.pid, $0.coalitionID) }, uniquingKeysWith: { a, _ in a })
        for (pid, nanoseconds) in gpuTime {
            guard let previous = lastGPUTime[pid], nanoseconds > previous else { continue }
            let delta = nanoseconds - previous
            if let id = coalitionOf[pid], id != 0, coalitions != nil {
                coalitionDeltas[id, default: .zero].gpuEnergyNJ &+= delta
            } else {
                processDeltas[pid, default: .zero].gpuEnergyNJ &+= delta
            }
        }
    }
}

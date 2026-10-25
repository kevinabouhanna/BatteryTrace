/// What every data source shares: whether it works on this Mac, and why not.
///
/// A source whose symbol, service, channel or key is missing reports
/// `isAvailable == false` and contributes nothing. The UI hides whatever it
/// would have shown. Nothing crashes.
public protocol DataSource: AnyObject {
    var sourceName: String { get }
    var isAvailable: Bool { get }
    /// What was found and what was missing, for `bttrace sources`.
    var diagnostics: [String] { get }
}

/// Energy per hardware component since the previous call.
///
/// To add a component (say, a Wi-Fi model), write one type conforming to this
/// and register it with the pipeline.
public protocol ComponentSource: DataSource {
    /// Appends energy since the last call. The first call after creation or
    /// `resetBaseline()` primes and appends nothing.
    /// - Parameter intervalSeconds: the interval the engine measured, for
    ///   sources that model power rather than count energy.
    func readComponents(intervalSeconds: Double, into out: inout [ComponentEnergy])
    /// Forgets the baseline, so an interval that spans sleep is never reported.
    func resetBaseline()
}

/// Fills in part of the System section: battery, CPU load, memory, display…
public protocol SnapshotSource: DataSource {
    func update(_ snapshot: inout SystemSnapshot)
}

/// A live reading of whole-system power, in watts.
public protocol LiveSystemPowerSource: DataSource {
    func readSystemWatts() -> Double?
}

/// The battery gauge's averaged telemetry: the ground truth for totals.
public protocol TelemetrySource: DataSource {
    /// A completed averaging window, if the gauge refreshed since the last call.
    func readTelemetryWindow(nowUptimeNS: UInt64) -> TelemetryWindow?
    func resetBaseline()
}

/// One interval of energy data, whichever provider produced it.
public struct PowerMetricsSample: Sendable {
    public var endUptimeNS: UInt64
    public var durationSeconds: Double
    public var components: [ComponentEnergy]
    /// Usage per resource coalition over the interval.
    public var coalitions: [UInt64: UsageCounters]
    /// Every live process at the end of the interval (for grouping and names).
    public var processes: [ProcessRecord]
    /// Usage per PID over the interval, for processes whose counters could be read.
    public var processDeltas: [Int32: UsageCounters]

    public init(endUptimeNS: UInt64, durationSeconds: Double, components: [ComponentEnergy],
                coalitions: [UInt64: UsageCounters], processes: [ProcessRecord],
                processDeltas: [Int32: UsageCounters]) {
        self.endUptimeNS = endUptimeNS
        self.durationSeconds = durationSeconds
        self.components = components
        self.coalitions = coalitions
        self.processes = processes
        self.processDeltas = processDeltas
    }
}

/// The seam for a more accurate, privileged source.
///
/// The MVP ships one implementation, `UnprivilegedPowerMetrics`, built from
/// IOReport, coalitions and `proc_pid_rusage`, with no root. A privileged
/// helper (an `SMAppService` daemon wrapping `powermetrics`) would implement
/// this same protocol, and attribution, storage and UI would not change.
public protocol PowerMetricsProvider: AnyObject {
    var providerName: String { get }
    var isAvailable: Bool { get }
    /// Usage since the previous call. Nil on the first call, which primes.
    func nextSample(nowUptimeNS: UInt64) -> PowerMetricsSample?
    func resetBaseline()
    /// Every source behind this provider, for diagnostics.
    var dataSources: [any DataSource] { get }
}

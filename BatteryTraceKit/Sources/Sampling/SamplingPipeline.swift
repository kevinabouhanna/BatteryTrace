import Attribution
import BatteryTraceCore
import Foundation
import PowerSources

/// The sampling layer, in two speeds:
///
/// - `quickTick()`: the live total and battery state, for the menu bar. About
///   0.3 ms. Each reading of the live total is integrated, so the measured
///   energy of the next full interval uses every reading, not two.
/// - `tick(detailed:)`: everything, grouped and attributed. Costs several
///   milliseconds, so the engine runs it once a minute while nobody looks.
///   Every counter it reads is cumulative, so it misses nothing in between.
///
/// Not thread-safe. The engine calls it on its own serial queue, and the
/// `bttrace` CLI on its main thread.
public final class SamplingPipeline {
    public let provider: any PowerMetricsProvider
    public let live: (any LiveSystemPowerSource)?
    public let telemetry: (any TelemetrySource)?
    /// Read every tick: cheap, and needed for the menu bar and history.
    public let essentialSnapshots: [any SnapshotSource]
    /// Read only while someone is looking: per-core load, memory, brightness.
    public let detailSnapshots: [any SnapshotSource]

    /// CPU time per stage of the last tick, for `bttrace cost`.
    public private(set) var lastTimings: [(stage: String, ns: UInt64)] = []
    /// The process table as of the last full tick, for validation tools
    /// that need to map PIDs to apps.
    public private(set) var lastProcesses: [ProcessRecord] = []

    private var grouper: AppGrouper
    private var snapshot = SystemSnapshot()
    private let energyWeightedSplits: Set<AppSplit>
    /// Off in the app: keeping the table would hold on to its storage.
    public var keepsProcessTable = false
    /// Count energy macOS services spend on an app's behalf as the app's.
    public var countsBilledEnergy = true

    // The live total, integrated between full ticks (trapezoids).
    private var lastLive: (uptimeNS: UInt64, watts: Double)?
    private var integratedJoules = 0.0
    private var integratedSeconds = 0.0

    public init(provider: any PowerMetricsProvider, live: (any LiveSystemPowerSource)?, telemetry: (any TelemetrySource)?,
                essentialSnapshots: [any SnapshotSource], detailSnapshots: [any SnapshotSource],
                bundleNamer: @escaping AppGrouper.BundleNamer, energyWeightedSplits: Set<AppSplit>) {
        self.provider = provider
        self.live = live?.isAvailable == true ? live : nil
        self.telemetry = telemetry?.isAvailable == true ? telemetry : nil
        self.essentialSnapshots = essentialSnapshots.filter(\.isAvailable)
        self.detailSnapshots = detailSnapshots.filter(\.isAvailable)
        self.energyWeightedSplits = energyWeightedSplits
        grouper = AppGrouper(bundleNamer: bundleNamer)
    }

    /// Every source on this Mac, wired up.
    public static func standard() -> SamplingPipeline {
        let smc = SMCSystemPowerSource()
        let battery = BatteryGaugeSource(sharing: smc)
        let display = DisplayBacklightSource()
        let metrics = UnprivilegedPowerMetrics.standard(display: display)
        var weighted: Set<AppSplit> = [.cpu]
        if metrics.gpuWeightsAreEnergy { weighted.formUnion([.gpu, .ane]) }
        let names = BundleNameCache()
        return SamplingPipeline(
            provider: metrics, live: smc, telemetry: battery,
            essentialSnapshots: [battery, ThermalSource()],
            detailSnapshots: [CPULoadSource(), MemorySource(), display],
            bundleNamer: { names.name(forBundle: $0) },
            energyWeightedSplits: weighted
        )
    }

    public var allSources: [any DataSource] {
        var sources = provider.dataSources
        if let live { sources.append(live) }
        if let telemetry, !sources.contains(where: { $0 === telemetry }) { sources.append(telemetry) }
        for s in essentialSnapshots + detailSnapshots where !sources.contains(where: { $0 === s }) { sources.append(s) }
        return sources
    }

    /// Forget every baseline. Call after the Mac wakes, so the interval
    /// that spans sleep is dropped rather than reported.
    public func resetBaselines() {
        provider.resetBaseline()
        telemetry?.resetBaseline()
        lastLive = nil
        integratedJoules = 0
        integratedSeconds = 0
    }

    /// Reads the live total and adds the stretch since the last reading.
    private func integrateLive(now: UInt64) -> Double? {
        guard let watts = live?.readSystemWatts() else { return nil }
        if let last = lastLive, now > last.uptimeNS {
            let seconds = Double(now - last.uptimeNS) / 1e9
            // A gap this long means a missed wake-up; don't draw a line across it.
            if seconds < 300 {
                integratedJoules += (watts + last.watts) / 2 * seconds
                integratedSeconds += seconds
            }
        }
        lastLive = (now, watts)
        return watts
    }

    /// The menu bar's reading: live total and battery. Cheap.
    public func quickTick() -> LiveReading {
        let now = Clock.uptimeNS()
        let watts = integrateLive(now: now)
        for source in essentialSnapshots { source.update(&snapshot) }
        snapshot.liveSystemWatts = watts
        return LiveReading(uptimeNS: now, date: Date(), systemWatts: watts, battery: snapshot.battery)
    }

    /// - Parameter detailed: also refresh the System section's detail
    ///   (only while the popover is visible).
    /// - Returns: nil on the first tick after a reset, which only primes.
    public func tick(detailed: Bool) -> IntervalReport? {
        let cpuStart = Clock.threadCPUTimeNS()
        let now = Clock.uptimeNS()

        var mark = cpuStart
        lastTimings.removeAll(keepingCapacity: true)
        func lap(_ stage: String) {
            let t = Clock.threadCPUTimeNS()
            lastTimings.append((stage, t &- mark))
            mark = t
        }

        // The live total first: read after the rest of the tick, it would
        // include Battery Trace's own burst of work.
        let liveWatts = integrateLive(now: now)
        lap("live total")
        let sample = provider.nextSample(nowUptimeNS: now)
        lap("provider")
        let window = telemetry?.readTelemetryWindow(nowUptimeNS: now)
        lap("telemetry")
        for source in essentialSnapshots { source.update(&snapshot) }
        lap("essential snapshots")
        if detailed { for source in detailSnapshots { source.update(&snapshot) } }
        lap("detail snapshots")
        snapshot.liveSystemWatts = liveWatts
        let integrated = (joules: integratedJoules, seconds: integratedSeconds)
        integratedJoules = 0
        integratedSeconds = 0

        guard let sample else { return nil }

        // The interval's measured energy: the live rail integrated over every
        // reading since the last full tick, scaled to the interval if a
        // reading or two is missing. Battery V × I is the fallback on battery.
        var measured: Double?
        var source: TotalSource?
        if integrated.seconds >= sample.durationSeconds * 0.8 {
            measured = integrated.joules * sample.durationSeconds / integrated.seconds
            source = .smc
        } else if let discharge = snapshot.battery.dischargeWatts {
            measured = discharge * sample.durationSeconds
            source = .batteryDischarge
        }

        let apps = grouper.group(processes: sample.processes, coalitions: sample.coalitions, processDeltas: sample.processDeltas)
        if keepsProcessTable { lastProcesses = sample.processes }
        lap("grouping")
        var report = EnergySplitter.attribute(EnergySplitter.Input(
            endUptimeNS: now, endDate: Date(), durationSeconds: sample.durationSeconds,
            onExternalPower: snapshot.battery.isPresent ? snapshot.battery.isOnExternalPower : true,
            measuredJoules: measured, measuredSource: source,
            components: sample.components, apps: apps, system: snapshot,
            energyWeightedSplits: energyWeightedSplits, billing: countsBilledEnergy
        ))
        lap("attribution")
        report.telemetry = window
        report.samplingCPUNS = Clock.threadCPUTimeNS() &- cpuStart
        return report
    }

    /// The System section without an energy sample, for the popover's first frame.
    public func currentSnapshot(detailed: Bool) -> SystemSnapshot {
        for source in essentialSnapshots { source.update(&snapshot) }
        if detailed { for source in detailSnapshots { source.update(&snapshot) } }
        snapshot.liveSystemWatts = integrateLive(now: Clock.uptimeNS())
        return snapshot
    }
}

/// App names and bundle IDs from `Info.plist`, read once per bundle.
///
/// Reads the plist directly rather than through `Bundle(path:)`, which keeps
/// every bundle it opens alive for the life of the process.
final class BundleNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: (name: String, bundleID: String?)] = [:]

    func name(forBundle path: String) -> (name: String, bundleID: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let cached = names[path] { return cached }
        let fallback = AppGrouper.fileNameBundleNamer(path)
        var result = fallback
        if let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            result = (display.flatMap { $0.isEmpty ? nil : $0 } ?? fallback.name, plist["CFBundleIdentifier"] as? String)
        }
        names[path] = result
        return result
    }
}

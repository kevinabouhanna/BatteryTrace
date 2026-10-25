import BatteryTraceCore

/// Running totals over a window (Last 5 min, 1 hour, 24 hours).
///
/// Intervals bring component and app energy. Telemetry windows bring the
/// battery gauge's measured averages. `summary()` reconciles the two, so the
/// window's rows add up to what the gauge measured.
public struct EnergyLedger: Sendable, Codable {
    public private(set) var durationSeconds: Double = 0
    /// Energy the live sensor measured, and over how much of the window.
    public private(set) var sensorJoules: Double = 0
    public private(set) var sensorSeconds: Double = 0
    public private(set) var sensorSource: TotalSource?
    /// Energy the battery gauge's telemetry measured, and over how long.
    public private(set) var telemetryJoules: Double = 0
    public private(set) var telemetrySeconds: Double = 0
    public private(set) var onBatterySeconds: Double = 0
    public private(set) var components: [ComponentID: ComponentTotal] = [:]
    public private(set) var apps: [AppKey: AppTotal] = [:]
    public private(set) var unclaimedJoules: Double = 0

    public struct ComponentTotal: Sendable, Codable, Hashable {
        public var joules: Double
        public var provenance: Provenance
    }

    public struct AppTotal: Sendable, Codable, Hashable {
        public var identity: AppIdentity
        public var cpuJoules: Double = 0
        public var gpuJoules: Double = 0
        public var aneJoules: Double = 0
        /// CPU energy by process name. PIDs come and go; names persist.
        public var processes: [String: Double] = [:]

        public init(identity: AppIdentity) { self.identity = identity }
        public var joules: Double { cpuJoules + gpuJoules + aneJoules }
    }

    public init() {}

    public mutating func add(_ report: IntervalReport) {
        durationSeconds += report.durationSeconds
        if !report.onExternalPower { onBatterySeconds += report.durationSeconds }
        if let measured = report.measuredJoules {
            sensorJoules += measured
            sensorSeconds += report.durationSeconds
            sensorSource = report.measuredSource
        }
        for component in report.components {
            addComponent(component.id, joules: component.joules, provenance: component.provenance)
        }
        unclaimedJoules += report.unclaimedJoules
        for app in report.apps {
            var total = apps[app.identity.key] ?? AppTotal(identity: app.identity)
            total.identity = app.identity
            total.cpuJoules += app.cpuJoules
            total.gpuJoules += app.gpuJoules
            total.aneJoules += app.aneJoules
            for process in app.processes { total.processes[process.name, default: 0] += process.cpuJoules }
            apps[app.identity.key] = total
        }
    }

    public mutating func add(_ window: TelemetryWindow) {
        telemetryJoules += window.systemLoadWatts * window.durationSeconds
        telemetrySeconds += window.durationSeconds
    }

    public mutating func addComponent(_ id: ComponentID, joules: Double, provenance: Provenance) {
        var total = components[id] ?? ComponentTotal(joules: 0, provenance: provenance)
        total.joules += joules
        total.provenance = max(total.provenance, provenance)
        components[id] = total
    }

    /// For loading stored history: a range of minutes' totals at once.
    public mutating func addStoredTotals(durationSeconds: Double, onBatterySeconds: Double,
                                         sensorJoules: Double, sensorSeconds: Double, sensorSource: TotalSource?,
                                         telemetryJoules: Double, telemetrySeconds: Double, unclaimedJoules: Double) {
        self.durationSeconds += durationSeconds
        self.onBatterySeconds += onBatterySeconds
        self.sensorJoules += sensorJoules
        self.sensorSeconds += sensorSeconds
        if let sensorSource { self.sensorSource = sensorSource }
        self.telemetryJoules += telemetryJoules
        self.telemetrySeconds += telemetrySeconds
        self.unclaimedJoules += unclaimedJoules
    }

    public mutating func addStoredApp(_ identity: AppIdentity, cpuJoules: Double, gpuJoules: Double, aneJoules: Double, processes: [String: Double]) {
        var total = apps[identity.key] ?? AppTotal(identity: identity)
        total.cpuJoules += cpuJoules
        total.gpuJoules += gpuJoules
        total.aneJoules += aneJoules
        for (name, joules) in processes { total.processes[name, default: 0] += joules }
        apps[identity.key] = total
    }

    public mutating func merge(_ other: EnergyLedger) {
        durationSeconds += other.durationSeconds
        sensorJoules += other.sensorJoules
        sensorSeconds += other.sensorSeconds
        sensorSource = other.sensorSource ?? sensorSource
        telemetryJoules += other.telemetryJoules
        telemetrySeconds += other.telemetrySeconds
        onBatterySeconds += other.onBatterySeconds
        unclaimedJoules += other.unclaimedJoules
        for (id, total) in other.components { addComponent(id, joules: total.joules, provenance: total.provenance) }
        for (key, app) in other.apps {
            var total = apps[key] ?? AppTotal(identity: app.identity)
            total.cpuJoules += app.cpuJoules
            total.gpuJoules += app.gpuJoules
            total.aneJoules += app.aneJoules
            for (name, joules) in app.processes { total.processes[name, default: 0] += joules }
            apps[key] = total
        }
    }

    public var isEmpty: Bool { durationSeconds == 0 }

    /// Below this share of the window, a measurement is too patchy to
    /// stand for the whole window.
    public static let minimumCoverage = 0.8

    public func summary() -> WindowSummary {
        let componentJoules = components.values.reduce(0) { $0 + $1.joules }
        var total = componentJoules
        var source: WindowSummary.TotalBasis = .componentsOnly
        if durationSeconds > 0, telemetrySeconds >= durationSeconds * Self.minimumCoverage {
            total = telemetryJoules * durationSeconds / telemetrySeconds
            source = .measured(.batteryTelemetry)
        } else if durationSeconds > 0, sensorSeconds >= durationSeconds * Self.minimumCoverage {
            total = sensorJoules * durationSeconds / sensorSeconds
            source = .measured(sensorSource ?? .smc)
        }

        // Rows must add up to the measured total. If the components overshoot
        // it (sensor timing, or a model that runs high), scale them to fit and
        // say so, rather than show more energy than was used.
        let scale = componentJoules > total && componentJoules > 0 ? total / componentJoules : 1
        let unattributed = source == .componentsOnly ? nil : Optional(max(0, total - componentJoules))

        let scaledComponents = components
            .map { ComponentEnergy(id: $0.key, joules: $0.value.joules * scale, provenance: $0.value.provenance) }
            .sorted { $0.id < $1.id }
        let appRows = apps.values
            .filter { $0.joules > 0 }
            .map { app in
                WindowSummary.AppRow(
                    identity: app.identity,
                    joules: app.joules * scale, cpuJoules: app.cpuJoules * scale,
                    gpuJoules: app.gpuJoules * scale, aneJoules: app.aneJoules * scale,
                    processes: app.processes
                        .map { ProcessShare(name: $0.key, pid: nil, cpuJoules: $0.value * scale) }
                        .filter { $0.cpuJoules > 0 }
                        .sorted { $0.cpuJoules > $1.cpuJoules }
                )
            }
            .sorted { $0.joules == $1.joules ? $0.identity.key < $1.identity.key : $0.joules > $1.joules }

        let nonApp = scaledComponents.filter { $0.id.appSplit == .none }.reduce(0) { $0 + $1.joules }
        return WindowSummary(
            durationSeconds: durationSeconds, onBatterySeconds: onBatterySeconds,
            totalJoules: total, basis: source, components: scaledComponents, apps: appRows,
            unclaimedJoules: unclaimedJoules * scale, unattributedJoules: unattributed,
            systemJoules: nonApp + unclaimedJoules * scale + (unattributed ?? 0), scale: scale
        )
    }
}

/// A window's totals, ready to show.
public struct WindowSummary: Sendable, Hashable {
    public enum TotalBasis: Sendable, Hashable {
        case measured(TotalSource)
        /// No measurement covered enough of the window: the total is just the
        /// sum of the components, and Unattributed is unknown.
        case componentsOnly
    }

    public struct AppRow: Sendable, Hashable, Identifiable {
        public var identity: AppIdentity
        public var joules: Double
        public var cpuJoules: Double
        public var gpuJoules: Double
        public var aneJoules: Double
        public var processes: [ProcessShare]
        public var id: AppKey { identity.key }
    }

    public var durationSeconds: Double
    public var onBatterySeconds: Double
    public var totalJoules: Double
    public var basis: TotalBasis
    public var components: [ComponentEnergy]
    public var apps: [AppRow]
    public var unclaimedJoules: Double
    public var unattributedJoules: Double?
    /// The System / Unattributed row.
    public var systemJoules: Double
    /// 1 unless the components overshot the measured total and were scaled.
    public var scale: Double

    public var averageWatts: Double { durationSeconds > 0 ? totalJoules / durationSeconds : 0 }

    public func share(of joules: Double) -> Double { totalJoules > 0 ? joules / totalJoules : 0 }

    /// Fraction of the measured total that no component accounts for.
    public var unattributedFraction: Double? { unattributedJoules.map { totalJoules > 0 ? $0 / totalJoules : 0 } }
}

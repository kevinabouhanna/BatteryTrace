import BatteryTraceCore
import Foundation

/// Spots apps that keep using a lot of power on battery. Pure.
///
/// An app is reported when it averaged at least `thresholdWatts` over the
/// whole of the last `window` seconds, every one of them on battery, and
/// hasn't been reported in the last `quietPeriod`. A burst is not a pattern:
/// the window must be fully covered before anything is reported.
public struct PowerHungryDetector: Sendable {
    public struct Alert: Sendable, Equatable {
        public let identity: AppIdentity
        public let averageWatts: Double
        public let seconds: Double

        public init(identity: AppIdentity, averageWatts: Double, seconds: Double) {
            self.identity = identity
            self.averageWatts = averageWatts
            self.seconds = seconds
        }
    }

    public var thresholdWatts: Double
    public var window: TimeInterval
    public var quietPeriod: TimeInterval

    private struct Slice {
        var start: Date
        var end: Date
        var duration: Double
        var onBattery: Bool
        var joules: [AppKey: Double]
    }

    private var slices: [Slice] = []
    private var identities: [AppKey: AppIdentity] = [:]
    private var lastAlert: [AppKey: Date] = [:]

    public init(thresholdWatts: Double, window: TimeInterval = 600, quietPeriod: TimeInterval = 3600) {
        self.thresholdWatts = thresholdWatts
        self.window = window
        self.quietPeriod = quietPeriod
    }

    /// Adds an interval; returns the apps that just crossed the line, the
    /// hungriest first.
    public mutating func add(_ report: IntervalReport) -> [Alert] {
        let end = report.endDate
        let start = end.addingTimeInterval(-report.durationSeconds)
        var joules: [AppKey: Double] = [:]
        for app in report.apps where app.identity.kind != .kernel && app.joules > 0 {
            joules[app.identity.key] = app.joules
            identities[app.identity.key] = app.identity
        }
        // Readings every 2 s while the popover is open fold into minute-long
        // slices, so ten minutes is never more than a dozen.
        if var last = slices.last, last.onBattery == !report.onExternalPower, end.timeIntervalSince(last.start) < 60 {
            last.end = end
            last.duration += report.durationSeconds
            last.joules.merge(joules, uniquingKeysWith: +)
            slices[slices.count - 1] = last
        } else {
            slices.append(Slice(start: start, end: end, duration: report.durationSeconds, onBattery: !report.onExternalPower, joules: joules))
        }
        let cutoff = end.addingTimeInterval(-window)
        slices.removeAll { $0.end <= cutoff }

        let covered = slices.reduce(0) { $0 + $1.duration }
        guard covered >= window * 0.9, slices.allSatisfy(\.onBattery),
              let first = slices.first, end.timeIntervalSince(first.start) <= window * 1.5
        else { return [] }

        var totals: [AppKey: Double] = [:]
        for slice in slices { totals.merge(slice.joules, uniquingKeysWith: +) }
        var alerts: [Alert] = []
        for (key, energy) in totals {
            let watts = energy / covered
            guard watts >= thresholdWatts, let identity = identities[key] else { continue }
            if let last = lastAlert[key], end.timeIntervalSince(last) < quietPeriod { continue }
            lastAlert[key] = end
            alerts.append(Alert(identity: identity, averageWatts: watts, seconds: covered))
        }
        if identities.count > 2048 { identities = identities.filter { totals[$0.key] != nil || lastAlert[$0.key] != nil } }
        return alerts.sorted { $0.averageWatts > $1.averageWatts }
    }
}

import Foundation

/// One minute of the battery's charge, for the Battery tab's chart.
public struct ChargePoint: Sendable, Hashable {
    public var date: Date
    public var percent: Double
    public var onExternalPower: Bool
    public var charging: Bool
}

/// One day's health reading.
public struct HealthPoint: Sendable, Hashable {
    public var day: Date
    /// The gauge's capacity relative to new: nominal ÷ design.
    public var gaugePercent: Double
    /// macOS's own "Maximum Capacity", from 0.8.0 on, when macOS gave one.
    public var macOSPercent: Int?
    public var cycles: Int?

    /// The days to draw a trend from, all in one measure: macOS's figure if
    /// the latest day has it (and only the days that do), else the gauge's.
    public static func trend(_ points: [HealthPoint]) -> [(day: Date, percent: Double)] {
        if points.last?.macOSPercent != nil {
            return points.compactMap { point in point.macOSPercent.map { (point.day, Double($0)) } }
        }
        return points.map { ($0.day, $0.gaugePercent) }
    }
}

/// What a stretch of charge history adds up to.
public struct ChargeSummary: Sendable, Hashable {
    public var onBatterySeconds: Double = 0
    /// Percentage points the charge fell while on battery.
    public var percentUsedOnBattery: Double = 0
    /// Times charging started.
    public var chargeSessions = 0
}

extension HistoryStore {
    /// The charge each recorded minute since `start`, buffered minutes included.
    public func chargeHistory(since start: Date) throws -> [ChargePoint] {
        var points: [ChargePoint] = []
        try db.statement("SELECT ts, battery_pct, on_ac, charging FROM minute WHERE ts >= ? AND battery_pct IS NOT NULL ORDER BY ts")
            .bind(Self.minute(of: start)).rows { row in
                points.append(ChargePoint(date: Date(timeIntervalSince1970: Double(row.int(0))), percent: row.double(1),
                                          onExternalPower: row.int(2) == 1, charging: row.int(3) == 1))
            }
        for (minute, meta) in pendingMeta.sorted(by: { $0.key < $1.key }) where minute >= Self.minute(of: start) {
            guard let percent = meta.batteryPercent else { continue }
            if let last = points.last, Int64(last.date.timeIntervalSince1970) >= minute { continue }
            points.append(ChargePoint(date: Date(timeIntervalSince1970: Double(minute)), percent: percent,
                                      onExternalPower: meta.onExternalPower, charging: meta.charging))
        }
        return points
    }

    /// One reading a day, oldest first, buffered day included.
    public func healthHistory() throws -> [HealthPoint] {
        var points: [Int64: HealthPoint] = [:]
        try db.statement("SELECT day, health, cycles, macos_pct FROM battery_daily ORDER BY day").rows { row in
            points[row.int(0)] = HealthPoint(day: Date(timeIntervalSince1970: Double(row.int(0))), gaugePercent: row.double(1),
                                             macOSPercent: row.isNull(3) ? nil : Int(row.int(3)),
                                             cycles: row.isNull(2) ? nil : Int(row.int(2)))
        }
        for (day, reading) in pendingDaily {
            points[day] = HealthPoint(day: Date(timeIntervalSince1970: Double(day)), gaugePercent: reading.health,
                                      macOSPercent: reading.macOSPercent, cycles: reading.cycles)
        }
        return points.values.sorted { $0.day < $1.day }
    }

    /// Time on battery, charge used on it, and charging sessions. Gaps (the
    /// Mac asleep or Battery Trace not running) count for nothing.
    public static func summarize(_ points: [ChargePoint]) -> ChargeSummary {
        var summary = ChargeSummary()
        var wasCharging = points.first?.charging ?? false
        if wasCharging { summary.chargeSessions = 1 }
        for (previous, point) in zip(points, points.dropFirst()) {
            let gap = point.date.timeIntervalSince(previous.date)
            if gap <= 180, !previous.onExternalPower {
                summary.onBatterySeconds += gap
                summary.percentUsedOnBattery += max(0, previous.percent - point.percent)
            }
            if point.charging, !wasCharging { summary.chargeSessions += 1 }
            wasCharging = point.charging
        }
        return summary
    }
}

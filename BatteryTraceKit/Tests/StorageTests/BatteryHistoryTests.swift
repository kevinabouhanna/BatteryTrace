import Attribution
import BatteryTraceCore
import Foundation
import SQLite3
@testable import Storage
import Testing

@Suite struct BatteryHistoryTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryTraceBattery-\(UUID().uuidString)")

    func report(at date: Date, percent: Double, onAC: Bool, charging: Bool, health: Bool = true, macOS: Int? = nil) -> IntervalReport {
        var system = SystemSnapshot()
        system.battery.isPresent = true
        system.battery.percent = percent
        system.battery.isOnExternalPower = onAC
        system.battery.isCharging = charging
        if health {
            system.battery.designCapacityMAh = 4382
            system.battery.nominalCapacityMAh = 3360
            system.battery.cycleCount = 625
            system.battery.macOSMaximumCapacityPercent = macOS
        }
        return IntervalReport(endUptimeNS: 0, endDate: date, durationSeconds: 60, onExternalPower: onAC,
                              measuredJoules: nil, measuredSource: nil, components: [], apps: [],
                              unclaimedJoules: 0, unattributedJoules: nil, overshootJoules: 0, system: system)
    }

    @Test func aHistoryFileFromBeforeChargingWasRecordedIsUpgradedInPlace() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.sqlite")
        var handle: OpaquePointer?
        sqlite3_open(url.path, &handle)
        sqlite3_exec(handle, """
        CREATE TABLE minute (ts INTEGER PRIMARY KEY, seconds REAL, battery_seconds REAL, sensor_j REAL, sensor_seconds REAL,
            sensor_src INTEGER, telemetry_j REAL, telemetry_seconds REAL, unclaimed_j REAL, battery_pct REAL, on_ac INTEGER) WITHOUT ROWID;
        INSERT INTO minute VALUES (\(Int(Date().timeIntervalSince1970 / 60) * 60 - 600), 60, 60, NULL, 0, NULL, 0, 0, 0, 81, 0);
        """, nil, nil, nil)
        sqlite3_close(handle)

        let history = try HistoryStore(url: url)
        let points = try history.chargeHistory(since: Date().addingTimeInterval(-3600))
        #expect(points.map(\.percent) == [81])
        #expect(points.first?.charging == false)
        history.record(report(at: Date(), percent: 80, onAC: true, charging: true))
        try history.flush()
        #expect(try history.chargeHistory(since: Date().addingTimeInterval(-3600)).last?.charging == true)
    }

    @Test func chargeAndHealthComeBackBeforeAndAfterAFlush() throws {
        let history = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date()
        for i in 0..<5 { history.record(report(at: now.addingTimeInterval(Double(i - 5) * 60), percent: 90 - Double(i), onAC: false, charging: false)) }
        let buffered = try history.chargeHistory(since: now.addingTimeInterval(-3600))
        let healthBuffered = try history.healthHistory()
        try history.flush(now: now)
        let stored = try history.chargeHistory(since: now.addingTimeInterval(-3600))
        #expect(buffered.map(\.percent) == [90, 89, 88, 87, 86])
        #expect(stored.map(\.percent) == buffered.map(\.percent))
        let health = try history.healthHistory()
        #expect(health.count == 1)
        #expect(healthBuffered == health)
        #expect(abs(health[0].gaugePercent - 76.68) < 0.01)
        #expect(health[0].macOSPercent == nil)
        #expect(health[0].cycles == 625)
    }

    @Test func macOSsFigureIsKeptBesideTheGaugesAndTrendsOnItsOwn() throws {
        let history = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let day: Double = 86400
        let now = Date()
        // Two days from before 0.8.0 (gauge only), then two with macOS's figure.
        history.record(report(at: now.addingTimeInterval(-3 * day), percent: 80, onAC: false, charging: false))
        history.record(report(at: now.addingTimeInterval(-2 * day), percent: 80, onAC: false, charging: false))
        history.record(report(at: now.addingTimeInterval(-1 * day), percent: 80, onAC: false, charging: false, macOS: 81))
        history.record(report(at: now, percent: 80, onAC: false, charging: false, macOS: 80))
        try history.flush(now: now)
        let points = try history.healthHistory()
        #expect(points.map(\.macOSPercent) == [nil, nil, 81, 80])
        #expect(points.allSatisfy { abs($0.gaugePercent - 76.68) < 0.01 })
        // The trend never mixes the two: 76.7 → 81 would be a jump that isn't there.
        #expect(HealthPoint.trend(points).map(\.percent) == [81, 80])
        #expect(HealthPoint.trend(Array(points.prefix(2))).count == 2)
    }

    @Test func aSummaryCountsTimeAndChargeUsedOnBatteryAndChargingSessions() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func point(_ minute: Int, _ percent: Double, onAC: Bool = false, charging: Bool = false) -> ChargePoint {
            ChargePoint(date: start.addingTimeInterval(Double(minute) * 60), percent: percent, onExternalPower: onAC, charging: charging)
        }
        let points = [
            point(0, 80, onAC: true, charging: true), point(1, 81, onAC: true, charging: true),   // charging when the window starts
            point(2, 81), point(3, 80), point(4, 79),                                            // 3 minutes on battery, 2 points used
            point(60, 70), point(61, 69),                                                        // a gap (asleep): not counted
            point(62, 69, onAC: true, charging: true), point(63, 70, onAC: true, charging: true), // charges again
        ]
        let summary = HistoryStore.summarize(points)
        #expect(summary.chargeSessions == 2)
        #expect(summary.onBatterySeconds == 4 * 60)
        #expect(summary.percentUsedOnBattery == 3)
    }
}

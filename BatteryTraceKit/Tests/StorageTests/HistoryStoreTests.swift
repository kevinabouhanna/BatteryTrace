import Attribution
import BatteryTraceCore
import Foundation
@testable import Storage
import Testing

@Suite struct HistoryStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryTraceTests-\(UUID().uuidString)")
    let chrome = AppIdentity(key: .bundle("/Applications/Google Chrome.app"), name: "Google Chrome", kind: .app, bundleID: "com.google.Chrome")

    func store() throws -> HistoryStore {
        try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    }

    func report(at date: Date, seconds: Double = 60, cpu: Double = 6, display: Double = 12, measured: Double = 30, appCPU: Double = 4) -> IntervalReport {
        let app = AppEnergy(identity: chrome, usage: .zero, cpuJoules: appCPU,
                            processes: [ProcessShare(name: "Google Chrome Helper (Renderer)", pid: 9, cpuJoules: appCPU)])
        return IntervalReport(
            endUptimeNS: 0, endDate: date, durationSeconds: seconds, onExternalPower: false,
            measuredJoules: measured, measuredSource: .smc,
            components: [ComponentEnergy(id: .cpu, joules: cpu, provenance: .measured),
                         ComponentEnergy(id: .displayBacklight, joules: display, provenance: .estimated)],
            apps: [app], unclaimedJoules: 0, unattributedJoules: measured - cpu - display, overshootJoules: 0,
            system: SystemSnapshot(),
            telemetry: TelemetryWindow(endUptimeNS: 0, durationSeconds: seconds, systemLoadWatts: measured / seconds, batteryWatts: nil))
    }

    @Test func whatIsRecordedComesBackTheSameBeforeAndAfterAFlush() throws {
        let history = try store()
        let now = Date()
        for minute in 0..<5 { history.record(report(at: now.addingTimeInterval(Double(minute - 5) * 60))) }
        let buffered = try history.ledger(since: now.addingTimeInterval(-600), now: now).summary()
        try history.flush(now: now)
        let stored = try history.ledger(since: now.addingTimeInterval(-600), now: now).summary()

        for summary in [buffered, stored] {
            #expect(abs(summary.durationSeconds - 300) < 1e-9)
            #expect(summary.basis == .measured(.batteryTelemetry))
            #expect(abs(summary.totalJoules - 150) < 1e-6)
            #expect(abs((summary.unattributedJoules ?? 0) - 60) < 1e-6)
            #expect(summary.components.first { $0.id == .displayBacklight }?.provenance == .estimated)
            let app = try #require(summary.apps.first)
            #expect(app.identity == chrome)
            #expect(abs(app.joules - 20) < 1e-9)
            #expect(app.processes.first?.name == "Google Chrome Helper (Renderer)")
        }
    }

    @Test func aMinuteSplitAcrossTwoFlushesIsAddedNotReplaced() throws {
        let history = try store()
        let minute = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 10)
        history.record(report(at: minute, seconds: 30, measured: 15))
        try history.flush(now: minute)
        history.record(report(at: minute.addingTimeInterval(20), seconds: 30, measured: 15))
        try history.flush(now: minute.addingTimeInterval(20))
        let summary = try history.ledger(since: minute.addingTimeInterval(-60), now: minute.addingTimeInterval(30)).summary()
        #expect(summary.durationSeconds == 60)
        #expect(abs(summary.totalJoules - 30) < 1e-6)
    }

    @Test func pruningRollsAppMinutesIntoHoursAndDropsWhatIsTooOld() throws {
        let history = try store()
        let now = Date()
        history.record(report(at: now.addingTimeInterval(-2 * 86400)))           // app minute rolled to hours
        history.record(report(at: now.addingTimeInterval(-8 * 86400)))           // past every retention
        history.record(report(at: now.addingTimeInterval(-120)))                 // fresh
        try history.flush(now: now)
        try history.prune(now: now)

        let week = try history.ledger(since: now.addingTimeInterval(-7 * 86400), now: now).summary()
        #expect(abs(week.durationSeconds - 120) < 1e-9)
        #expect(abs((week.apps.first?.joules ?? 0) - 8) < 1e-9) // 4 J from the hour roll-up + 4 J fresh
        let day = try history.ledger(since: now.addingTimeInterval(-86400), now: now).summary()
        #expect(abs((day.apps.first?.joules ?? 0) - 4) < 1e-9)
    }

    @Test func liveReadingsAndComponentSeriesForSparklines() throws {
        let history = try store()
        let now = Date()
        for i in 0..<12 {
            var battery = BatterySnapshot()
            battery.percent = 80
            history.record(LiveReading(uptimeNS: 0, date: now.addingTimeInterval(Double(i * 5) - 60), systemWatts: Double(i), battery: battery))
        }
        history.record(report(at: now.addingTimeInterval(-30)))
        let pending = try history.liveSeries(since: now.addingTimeInterval(-3600))
        try history.flush(now: now)
        let stored = try history.liveSeries(since: now.addingTimeInterval(-3600))
        #expect(pending.count == 12)
        #expect(stored.map(\.watts) == pending.map(\.watts))
        let cpu = try history.componentSeries(.cpu, since: now.addingTimeInterval(-3600))
        #expect(cpu.count == 1)
        #expect(abs(cpu[0].watts - 0.1) < 1e-9)
    }
}

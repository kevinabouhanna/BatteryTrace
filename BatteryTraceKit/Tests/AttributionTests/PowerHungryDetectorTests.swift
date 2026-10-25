@testable import Attribution
import BatteryTraceCore
import Foundation
import Testing

@Suite struct PowerHungryDetectorTests {
    let chrome = AppIdentity(key: .bundle("/Applications/Google Chrome.app"), name: "Google Chrome", kind: .app)
    let notes = AppIdentity(key: .bundle("/System/Applications/Notes.app"), name: "Notes", kind: .app)
    let start = Date(timeIntervalSince1970: 1_000_000)

    func minute(_ index: Int, chromeWatts: Double, notesWatts: Double = 0.1, onAC: Bool = false) -> IntervalReport {
        IntervalReport(endUptimeNS: 0, endDate: start.addingTimeInterval(Double(index + 1) * 60), durationSeconds: 60,
                       onExternalPower: onAC, measuredJoules: nil, measuredSource: nil, components: [],
                       apps: [AppEnergy(identity: chrome, usage: .zero, cpuJoules: chromeWatts * 60),
                              AppEnergy(identity: notes, usage: .zero, cpuJoules: notesWatts * 60)],
                       unclaimedJoules: 0, unattributedJoules: nil, overshootJoules: 0, system: SystemSnapshot())
    }

    @Test func tenFullMinutesOverTheLineAreReportedOnce() {
        var detector = PowerHungryDetector(thresholdWatts: 2)
        var alerts: [[PowerHungryDetector.Alert]] = []
        for i in 0..<15 { alerts.append(detector.add(minute(i, chromeWatts: 3))) }
        // Nothing until ten minutes are covered (≥ 90%: the 9th minute), then once.
        #expect(alerts[0..<8].allSatisfy { $0.isEmpty })
        let reported = alerts.flatMap { $0 }
        #expect(reported.count == 1)
        #expect(reported.first?.identity == chrome)
        #expect(abs((reported.first?.averageWatts ?? 0) - 3) < 1e-9)
    }

    @Test func aShortBurstIsNotAPattern() {
        var detector = PowerHungryDetector(thresholdWatts: 2)
        var reported: [PowerHungryDetector.Alert] = []
        for i in 0..<12 { reported += detector.add(minute(i, chromeWatts: i < 3 ? 10 : 0.5)) }
        // 30 W·min over ~10 minutes is 3 W at first, but the burst ages out.
        #expect(reported.allSatisfy { $0.averageWatts >= 2 })
        var calm = PowerHungryDetector(thresholdWatts: 2)
        var none: [PowerHungryDetector.Alert] = []
        for i in 0..<12 { none += calm.add(minute(i, chromeWatts: i == 5 ? 12 : 0.5)) }
        #expect(none.isEmpty)
    }

    @Test func nothingIsReportedWhileOnThePowerAdapter() {
        var detector = PowerHungryDetector(thresholdWatts: 2)
        var reported: [PowerHungryDetector.Alert] = []
        for i in 0..<12 { reported += detector.add(minute(i, chromeWatts: 5, onAC: i == 4)) }
        #expect(reported.isEmpty)
    }

    @Test func anAppIsReportedAgainOnlyAfterTheQuietPeriod() {
        var detector = PowerHungryDetector(thresholdWatts: 2, window: 600, quietPeriod: 3600)
        var times: [Int] = []
        for i in 0..<130 where !detector.add(minute(i, chromeWatts: 3)).isEmpty { times.append(i) }
        #expect(times.count == 3)
        #expect(times[1] - times[0] == 60)
    }

    @Test func readingsEveryTwoSecondsFoldIntoMinutes() {
        var detector = PowerHungryDetector(thresholdWatts: 2)
        var reported: [PowerHungryDetector.Alert] = []
        for i in 0..<330 {
            let report = IntervalReport(endUptimeNS: 0, endDate: start.addingTimeInterval(Double(i + 1) * 2), durationSeconds: 2,
                                        onExternalPower: false, measuredJoules: nil, measuredSource: nil, components: [],
                                        apps: [AppEnergy(identity: chrome, usage: .zero, cpuJoules: 6)],
                                        unclaimedJoules: 0, unattributedJoules: nil, overshootJoules: 0, system: SystemSnapshot())
            reported += detector.add(report)
        }
        #expect(reported.count == 1)
        #expect(abs((reported.first?.averageWatts ?? 0) - 3) < 1e-9)
    }
}

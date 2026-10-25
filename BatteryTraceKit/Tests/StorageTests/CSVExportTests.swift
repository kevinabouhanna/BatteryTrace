import Attribution
import BatteryTraceCore
import Foundation
@testable import Storage
import Testing

@Suite struct CSVExportTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryTraceCSV-\(UUID().uuidString)")

    func report(at date: Date, app name: String, cpu: Double) -> IntervalReport {
        let identity = AppIdentity(key: .bundle("/Applications/\(name).app"), name: name, kind: .app, bundleID: "com.example.app")
        return IntervalReport(
            endUptimeNS: 0, endDate: date, durationSeconds: 60, onExternalPower: false,
            measuredJoules: 300, measuredSource: .smc,
            components: [ComponentEnergy(id: .cpu, joules: 36, provenance: .measured),
                         ComponentEnergy(id: .displayBacklight, joules: 120, provenance: .estimated)],
            apps: [AppEnergy(identity: identity, usage: .zero, cpuJoules: cpu)],
            unclaimedJoules: 0, unattributedJoules: 144, overshootJoules: 0, system: SystemSnapshot())
    }

    @Test func appsAndSystemComeOutInWattHours() throws {
        let history = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date()
        history.record(report(at: now.addingTimeInterval(-90), app: "Editor", cpu: 36))
        let export = try history.exportCSV(since: now.addingTimeInterval(-3600), now: now)

        let apps = export.apps.split(separator: "\n")
        #expect(apps.first == "start,resolution_minutes,app,bundle_id,kind,cpu_wh,gpu_wh,ane_wh,total_wh")
        #expect(apps.count == 2)
        #expect(apps[1].contains(",1,Editor,com.example.app,app,0.010000,0.000000,0.000000,0.010000"))

        let system = export.system.split(separator: "\n")
        #expect(system.first?.contains("display_backlight_wh_estimate") == true)
        let row = system[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let header = system[0].split(separator: ",").map(String.init)
        func value(_ column: String) -> String { row[header.firstIndex(of: column)!] }
        #expect(value("measured_wh") == "0.083333")
        #expect(value("cpu_wh") == "0.010000")
        #expect(value("display_backlight_wh_estimate") == "0.033333")
        #expect(value("unattributed_wh") == "0.040000")
        #expect(value("on_power_adapter") == "no")
    }

    @Test func namesWithCommasAndQuotesAreQuoted() {
        #expect(HistoryStore.field("Plain") == "Plain")
        #expect(HistoryStore.field("Docs, Sheets") == "\"Docs, Sheets\"")
        #expect(HistoryStore.field("The \"Best\" App") == "\"The \"\"Best\"\" App\"")
    }
}

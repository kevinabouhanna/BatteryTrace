@testable import Attribution
import BatteryTraceCore
import Foundation
import Testing

@Suite struct EnergyLedgerTests {
    func report(seconds: Double = 60, measured: Double?, components: [ComponentEnergy], apps: [AppEnergy] = []) -> IntervalReport {
        IntervalReport(endUptimeNS: 0, endDate: Date(), durationSeconds: seconds, onExternalPower: false,
                       measuredJoules: measured, measuredSource: measured == nil ? nil : .smc, components: components,
                       apps: apps, unclaimedJoules: 0, unattributedJoules: nil, overshootJoules: 0, system: SystemSnapshot())
    }

    let chrome = AppIdentity(key: .bundle("/Applications/Google Chrome.app"), name: "Google Chrome", kind: .app)

    @Test func theBatteryGaugeIsPreferredOverTheLiveSensor() {
        var ledger = EnergyLedger()
        for _ in 0..<5 {
            ledger.add(report(measured: 300, components: [ComponentEnergy(id: .cpu, joules: 120, provenance: .measured)]))
            ledger.add(TelemetryWindow(endUptimeNS: 0, durationSeconds: 60, systemLoadWatts: 4.5, batteryWatts: 4.5))
        }
        let summary = ledger.summary()
        #expect(summary.basis == .measured(.batteryTelemetry))
        #expect(abs(summary.totalJoules - 1350) < 1e-9)
        #expect(abs((summary.unattributedJoules ?? 0) - 750) < 1e-9)
    }

    @Test func patchyGaugeCoverageFallsBackToTheSensor() {
        var ledger = EnergyLedger()
        for _ in 0..<5 { ledger.add(report(measured: 300, components: [])) }
        ledger.add(TelemetryWindow(endUptimeNS: 0, durationSeconds: 60, systemLoadWatts: 9, batteryWatts: 9))
        #expect(ledger.summary().basis == .measured(.smc))
        #expect(ledger.summary().totalJoules == 1500)
    }

    @Test func componentsAboveTheTotalAreScaledToFit() throws {
        var ledger = EnergyLedger()
        let app = AppEnergy(identity: chrome, usage: .zero, cpuJoules: 100, processes: [ProcessShare(name: "Google Chrome", pid: 1, cpuJoules: 100)])
        ledger.add(report(measured: 150, components: [ComponentEnergy(id: .cpu, joules: 100, provenance: .measured),
                                                      ComponentEnergy(id: .displayBacklight, joules: 100, provenance: .estimated)], apps: [app]))
        let summary = ledger.summary()
        #expect(summary.scale == 0.75)
        #expect(summary.unattributedJoules == 0)
        let row = try #require(summary.apps.first)
        #expect(row.joules == 75)
        #expect(abs(row.joules + summary.systemJoules - summary.totalJoules) < 1e-9)
    }

    @Test func withoutAMeasurementTheTotalIsTheComponentsAndUnattributedIsUnknown() {
        var ledger = EnergyLedger()
        ledger.add(report(measured: nil, components: [ComponentEnergy(id: .cpu, joules: 10, provenance: .measured)]))
        let summary = ledger.summary()
        #expect(summary.basis == .componentsOnly)
        #expect(summary.totalJoules == 10)
        #expect(summary.unattributedJoules == nil)
    }

    @Test func processesAreMergedByNameAcrossIntervals() throws {
        var ledger = EnergyLedger()
        for pid in [Int32(10), 11] {
            let app = AppEnergy(identity: chrome, usage: .zero, cpuJoules: 2,
                                processes: [ProcessShare(name: "Renderer", pid: pid, cpuJoules: 2)])
            ledger.add(report(measured: 10, components: [ComponentEnergy(id: .cpu, joules: 2, provenance: .measured)], apps: [app]))
        }
        let row = try #require(ledger.summary().apps.first)
        #expect(row.processes.map(\.name) == ["Renderer"])
        #expect(row.processes[0].cpuJoules == 4)
    }

    @Test func mergingTwoLedgersEqualsAddingEverythingToOne() {
        var a = EnergyLedger(), b = EnergyLedger(), both = EnergyLedger()
        let first = report(measured: 50, components: [ComponentEnergy(id: .gpu, joules: 5, provenance: .measured)])
        let second = report(measured: 70, components: [ComponentEnergy(id: .gpu, joules: 9, provenance: .measured)])
        a.add(first); both.add(first)
        b.add(second); both.add(second)
        a.merge(b)
        #expect(a.summary() == both.summary())
    }
}

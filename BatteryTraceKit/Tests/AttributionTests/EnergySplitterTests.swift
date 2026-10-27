@testable import Attribution
import BatteryTraceCore
import Foundation
import Testing

@Suite struct EnergySplitterTests {
    func input(components: [ComponentEnergy], apps: [AppUsage], measured: Double?,
               weighted: Set<AppSplit> = [.cpu, .gpu, .ane]) -> EnergySplitter.Input {
        EnergySplitter.Input(endUptimeNS: 0, endDate: Date(timeIntervalSince1970: 0), durationSeconds: 5, onExternalPower: false,
                             measuredJoules: measured, measuredSource: measured == nil ? nil : .smc,
                             components: components, apps: apps, energyWeightedSplits: weighted)
    }

    func app(_ name: String, cpu: UInt64 = 0, gpu: UInt64 = 0, ane: UInt64 = 0) -> AppUsage {
        AppUsage(identity: AppIdentity(key: .command(name), name: name, kind: .app), usage: Fixture.usage(cpu: cpu, gpu: gpu, ane: ane))
    }

    @Test func cpuIsSplitInProportionToEachAppsKernelEnergy() throws {
        let report = EnergySplitter.attribute(input(
            components: [ComponentEnergy(id: .cpu, joules: 10, provenance: .measured)],
            apps: [app("A", cpu: 3), app("B", cpu: 1)], measured: 10))
        #expect(report.apps.map(\.identity.name) == ["A", "B"])
        #expect(abs(report.apps[0].cpuJoules - 7.5) < 1e-9)
        #expect(abs(report.apps[1].cpuJoules - 2.5) < 1e-9)
        #expect(report.unattributedJoules == 0)
    }

    @Test func gpuAndANEFollowTheirOwnCounters() throws {
        let report = EnergySplitter.attribute(input(
            components: [ComponentEnergy(id: .cpu, joules: 4, provenance: .measured),
                         ComponentEnergy(id: .gpu, joules: 6, provenance: .measured),
                         ComponentEnergy(id: .ane, joules: 1, provenance: .measured)],
            apps: [app("Game", cpu: 1, gpu: 9), app("Editor", cpu: 3, gpu: 1, ane: 5)], measured: 20))
        let game = try #require(report.apps.first { $0.identity.name == "Game" })
        let editor = try #require(report.apps.first { $0.identity.name == "Editor" })
        #expect(abs(game.gpuJoules - 5.4) < 1e-9)
        #expect(abs(editor.gpuJoules - 0.6) < 1e-9)
        #expect(abs(editor.aneJoules - 1) < 1e-9)
        #expect(game.aneJoules == 0)
    }

    @Test func rowsAlwaysAddUpToTheMeasuredTotal() {
        // Random fixtures: apps + System == measured, whenever
        // the components don't exceed the measurement.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let cpu = Double.random(in: 0...5, using: &generator)
            let gpu = Double.random(in: 0...3, using: &generator)
            let memory = Double.random(in: 0...1, using: &generator)
            let display = Double.random(in: 0...4, using: &generator)
            let measured = cpu + gpu + memory + display + Double.random(in: 0...3, using: &generator)
            let apps = (0..<Int.random(in: 0...12, using: &generator)).map {
                app("app\($0)", cpu: UInt64.random(in: 0...1_000_000, using: &generator), gpu: UInt64.random(in: 0...1_000_000, using: &generator))
            }
            let report = EnergySplitter.attribute(input(components: [
                ComponentEnergy(id: .cpu, joules: cpu, provenance: .measured),
                ComponentEnergy(id: .gpu, joules: gpu, provenance: .measured),
                ComponentEnergy(id: .memory, joules: memory, provenance: .measured),
                ComponentEnergy(id: .displayBacklight, joules: display, provenance: .estimated),
            ], apps: apps, measured: measured))
            #expect(abs(report.totalJoules - measured) < 1e-6)
            #expect(report.overshootJoules == 0)
        }
    }

    @Test func componentsAboveTheMeasurementAreReportedNotHidden() {
        let report = EnergySplitter.attribute(input(
            components: [ComponentEnergy(id: .cpu, joules: 6, provenance: .measured),
                         ComponentEnergy(id: .displayBacklight, joules: 2, provenance: .estimated)],
            apps: [app("A", cpu: 1)], measured: 7))
        #expect(report.unattributedJoules == 0)
        #expect(abs(report.overshootJoules - 1) < 1e-9)
    }

    @Test func energyNoAppClaimsStaysInTheSystemRow() {
        let report = EnergySplitter.attribute(input(
            components: [ComponentEnergy(id: .gpu, joules: 2, provenance: .measured)],
            apps: [app("A", cpu: 1)], measured: 3))
        #expect(report.unclaimedJoules == 2)
        // A's 1 nJ of CPU weight becomes a 1 nJ estimated CPU component.
        #expect(abs(report.systemJoules - 3) < 1e-6)
    }

    @Test func withoutAHardwareCounterTheKernelModelStandsInMarkedAsAnEstimate() throws {
        let report = EnergySplitter.attribute(input(components: [], apps: [app("A", cpu: 2_000_000_000)], measured: nil))
        let cpu = try #require(report.components.first { $0.id == .cpu })
        #expect(cpu.joules == 2)
        #expect(cpu.provenance == .estimated)
        #expect(report.unattributedJoules == nil)
    }

    @Test func gpuTimeWeightsAreNeverPassedOffAsEnergy() {
        // macOS 14: GPU weights are driver time, so no GPU component is invented.
        let report = EnergySplitter.attribute(input(components: [], apps: [app("A", gpu: 5_000_000_000)], measured: nil, weighted: [.cpu]))
        #expect(report.components.isEmpty)
        #expect(report.apps.isEmpty)
    }

    @Test func childRowsAddUpToTheApp() throws {
        let apps = Fixture.grouped()
        let report = EnergySplitter.attribute(input(
            components: [ComponentEnergy(id: .cpu, joules: 3.25, provenance: .measured)], apps: apps, measured: 4))
        let chrome = try #require(report.apps.first { $0.identity.name == "Google Chrome" })
        let sum = chrome.processes.reduce(0) { $0 + $1.cpuJoules }
        #expect(abs(sum - chrome.cpuJoules) < 1e-9)
        // 50 mJ of Chrome's 1 J of kernel energy came from no readable process.
        let other = try #require(chrome.processes.first { $0.name == ProcessShare.otherProcessesName })
        #expect(abs(other.cpuJoules / chrome.cpuJoules - 0.05) < 1e-9)
        // WindowServer's counters were unreadable: its whole share is "other".
        let windowServer = try #require(report.apps.first { $0.identity.name == "WindowServer" })
        #expect(windowServer.processes.map(\.name) == [ProcessShare.otherProcessesName])
    }

    @Test func duplicateComponentsAreMerged() {
        let report = EnergySplitter.attribute(input(
            components: [ComponentEnergy(id: .otherSoC, joules: 1, provenance: .measured),
                         ComponentEnergy(id: .otherSoC, joules: 0.5, provenance: .estimated)],
            apps: [], measured: 2))
        #expect(report.components.count == 1)
        #expect(report.components[0].joules == 1.5)
        #expect(report.components[0].provenance == .estimated)
    }

    @Test func billingMovesWorkDoneForAnAppToThatApp() throws {
        // mds did 10 units of CPU work, 4 of them indexing Notes' files.
        let daemon = AppUsage(identity: AppIdentity(key: .executable("/usr/libexec/mds"), name: "mds", kind: .system),
                              usage: UsageCounters(cpuEnergyNJ: 10, cpuBilledToOthersNJ: 4))
        let notes = AppUsage(identity: AppIdentity(key: .bundle("/System/Applications/Notes.app"), name: "Notes", kind: .app),
                             usage: UsageCounters(cpuEnergyNJ: 2, cpuBilledToMeNJ: 4))
        let components = [ComponentEnergy(id: .cpu, joules: 12, provenance: .measured)]

        let direct = EnergySplitter.attribute(input(components: components, apps: [daemon, notes], measured: 12))
        #expect(direct.apps.first { $0.identity.name == "mds" }?.cpuJoules == 10)

        var billedInput = input(components: components, apps: [daemon, notes], measured: 12)
        billedInput.billing = true
        let billed = EnergySplitter.attribute(billedInput)
        let mds = try #require(billed.apps.first { $0.identity.name == "mds" })
        let app = try #require(billed.apps.first { $0.identity.name == "Notes" })
        #expect(mds.cpuJoules == 6)
        #expect(app.cpuJoules == 6)
        #expect(abs(billed.totalJoules - direct.totalJoules) < 1e-9)
    }

    @Test func billingNeverMakesAWeightNegative() {
        let usage = UsageCounters(cpuEnergyNJ: 3, gpuEnergyNJ: 1, cpuBilledToOthersNJ: 5, gpuBilledToMeNJ: 2, gpuBilledToOthersNJ: 9)
        #expect(usage.value(for: .cpu, billing: true) == 0)
        #expect(usage.value(for: .gpu, billing: true) == 0)
        #expect(usage.value(for: .cpu) == 3)
    }
}

@testable import Attribution
import BatteryTraceCore
import Testing

@Suite struct AppGrouperTests {
    @Test func helpersRollUpIntoTheirApp() throws {
        let apps = Fixture.grouped()
        let chrome = try #require(apps.app(named: "Google Chrome"))
        #expect(chrome.identity.key == .bundle(Fixture.chrome))
        #expect(chrome.identity.kind == .app)
        // Both of Chrome's coalitions, the browser's and the updater's, merge.
        #expect(chrome.coalitionIDs.sorted() == [1496, 1600])
        #expect(chrome.usage.cpuEnergyNJ == 1_000_000_000)
        #expect(chrome.usage.gpuEnergyNJ == 300_000_000)
        #expect(Set(chrome.processes.map(\.name)) == ["Google Chrome", "Google Chrome Helper (Renderer)", "Google Chrome Helper (GPU)", "GoogleUpdater"])
    }

    @Test func xpcServicesBelongToTheAppThatUsesThem() throws {
        let apps = Fixture.grouped()
        let safari = try #require(apps.app(named: "Safari"))
        #expect(safari.processes.map(\.name).contains("com.apple.WebKit.WebContent"))
        #expect(safari.usage.aneEnergyNJ == 10_000_000)
        #expect(apps.app(named: "com.apple.WebKit.WebContent") == nil)
    }

    @Test func otherUsersDaemonsAreGroupedThoughTheirCountersAreUnreadable() throws {
        let apps = Fixture.grouped()
        let windowServer = try #require(apps.app(named: "WindowServer"))
        #expect(windowServer.identity.kind == .system)
        #expect(windowServer.unreadableProcessCount == 1)
        #expect(windowServer.processes.isEmpty)
        #expect(windowServer.usage.cpuEnergyNJ == 100_000_000)
    }

    @Test func theKernelIsItsOwnRow() throws {
        let kernel = try #require(Fixture.grouped().first { $0.identity.key == .kernel })
        #expect(kernel.identity.kind == .kernel)
        #expect(kernel.usage.cpuEnergyNJ == 50_000_000)
    }

    @Test func toolsLaunchedFromATerminalCountForTheTerminal() throws {
        // As in Activity Monitor: the kernel puts them in the terminal's coalition.
        let terminal = try #require(Fixture.grouped().app(named: "Terminal"))
        #expect(terminal.processes.contains { $0.name == "swift-frontend" })
    }

    @Test func aCoalitionKeepsItsNameAfterItsProcessesExit() throws {
        var grouper = AppGrouper()
        _ = grouper.group(processes: Fixture.processes, coalitions: Fixture.coalitions, processDeltas: Fixture.processDeltas)
        // Next interval: the updater has exited but its coalition still reports usage.
        let remaining = Fixture.processes.filter { $0.coalitionID != 1600 }
        let apps = grouper.group(processes: remaining, coalitions: [1600: Fixture.usage(cpu: 7)], processDeltas: [:])
        #expect(apps.count == 1)
        #expect(apps[0].identity.name == "Google Chrome")
        #expect(apps[0].usage.cpuEnergyNJ == 7)
    }

    @Test func aNameIsWorkedOutAgainWhenTheLeaderChanges() throws {
        var grouper = AppGrouper()
        let tool = ProcessRecord(pid: 900, name: "tool", path: "/usr/local/bin/tool", coalitionID: 42)
        _ = grouper.group(processes: [tool], coalitions: [42: Fixture.usage(cpu: 1)], processDeltas: [:])
        // The tool exits; an app takes the coalition ID over with a lower PID.
        let app = ProcessRecord(pid: 100, name: "Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes", coalitionID: 42)
        let apps = grouper.group(processes: [app], coalitions: [42: Fixture.usage(cpu: 1)], processDeltas: [:])
        #expect(apps.first?.identity.name == "Notes")
    }

    @Test func withoutCoalitionsProcessesFollowTheirAncestors() throws {
        var grouper = AppGrouper()
        let apps = grouper.group(processes: Fixture.processes, coalitions: [:], processDeltas: Fixture.processDeltas)
        // swift-frontend has no bundle of its own; its parent is Terminal.
        let terminal = try #require(apps.app(named: "Terminal"))
        #expect(terminal.usage.cpuEnergyNJ == 1_200_000_000)
        let chrome = try #require(apps.app(named: "Google Chrome"))
        #expect(chrome.usage.cpuEnergyNJ == 950_000_000)
    }

    @Test func idleCoalitionsProduceNoRows() {
        var grouper = AppGrouper()
        let apps = grouper.group(processes: Fixture.processes, coalitions: [1496: Fixture.usage(cpu: 5)], processDeltas: [:])
        #expect(apps.map(\.identity.name) == ["Google Chrome"])
    }

    @Test(arguments: [
        ("/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Y Helper.app/Contents/MacOS/Y Helper", "/Applications/Google Chrome.app"),
        ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "/System/Library/CoreServices/Finder.app"),
        ("/usr/libexec/opendirectoryd", nil),
        ("/Users/me/Apps/My.application/bin/tool", nil),
    ])
    func outermostBundle(path: String, expected: String?) {
        #expect(AppGrouper.outermostBundle(of: path) == expected)
    }

    @Test func kinds() {
        #expect(AppGrouper.kind(ofBundle: "/System/Library/CoreServices/Dock.app") == .system)
        #expect(AppGrouper.kind(ofBundle: "/System/Applications/Mail.app") == .app)
        #expect(AppGrouper.kind(ofExecutable: "/usr/libexec/airportd") == .system)
        #expect(AppGrouper.kind(ofExecutable: "/opt/homebrew/bin/node") == .other)
    }
}

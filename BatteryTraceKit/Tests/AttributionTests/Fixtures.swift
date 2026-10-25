@testable import Attribution
import BatteryTraceCore
import Foundation

/// A small, realistic process table: Chrome with helpers in two coalitions,
/// Safari with a WebKit XPC service, WindowServer (another user's process),
/// the kernel, and a tool launched from Terminal.
enum Fixture {
    static let chrome = "/Applications/Google Chrome.app"
    static let chromeHelpers = chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/131/Helpers"

    static let processes: [ProcessRecord] = [
        ProcessRecord(pid: 0, name: "kernel_task", coalitionID: 1),
        ProcessRecord(pid: 690, parentPID: 1, uid: 88, name: "WindowServer",
                      path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer", coalitionID: 389),
        ProcessRecord(pid: 2280, parentPID: 1, uid: 501, name: "Google Chrome", path: chrome + "/Contents/MacOS/Google Chrome", coalitionID: 1496),
        ProcessRecord(pid: 2290, parentPID: 2280, uid: 501, name: "Google Chrome Helper (Renderer)",
                      path: chromeHelpers + "/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", coalitionID: 1496),
        ProcessRecord(pid: 2291, parentPID: 2280, uid: 501, name: "Google Chrome Helper (GPU)",
                      path: chromeHelpers + "/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)", coalitionID: 1496),
        // Chrome's updater, started by launchd in a coalition of its own.
        ProcessRecord(pid: 3001, parentPID: 1, uid: 501, name: "GoogleUpdater",
                      path: chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Helpers/GoogleUpdater.app/Contents/MacOS/GoogleUpdater",
                      coalitionID: 1600),
        ProcessRecord(pid: 4000, parentPID: 1, uid: 501, name: "Safari",
                      path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari", coalitionID: 1700),
        ProcessRecord(pid: 4010, parentPID: 1, uid: 501, name: "com.apple.WebKit.WebContent",
                      path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                      coalitionID: 1700),
        ProcessRecord(pid: 5000, parentPID: 1, uid: 501, name: "Terminal",
                      path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", coalitionID: 1800),
        ProcessRecord(pid: 5050, parentPID: 5000, uid: 501, name: "swift-frontend",
                      path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", coalitionID: 1800),
    ]

    static func usage(cpu: UInt64 = 0, gpu: UInt64 = 0, ane: UInt64 = 0) -> UsageCounters {
        UsageCounters(cpuEnergyNJ: cpu, gpuEnergyNJ: gpu, aneEnergyNJ: ane)
    }

    static let coalitions: [UInt64: UsageCounters] = [
        1: usage(cpu: 50_000_000),
        389: usage(cpu: 100_000_000, gpu: 40_000_000),
        1496: usage(cpu: 900_000_000, gpu: 300_000_000),
        1600: usage(cpu: 100_000_000),
        1700: usage(cpu: 400_000_000, gpu: 60_000_000, ane: 10_000_000),
        1800: usage(cpu: 1_200_000_000),
    ]

    /// Our own user's processes are readable; WindowServer and the kernel aren't.
    static let processDeltas: [Int32: UsageCounters] = [
        2280: usage(cpu: 300_000_000),
        2290: usage(cpu: 500_000_000),
        2291: usage(cpu: 50_000_000), // 50 mJ of Chrome's 900 unaccounted: an exited helper
        3001: usage(cpu: 100_000_000),
        4000: usage(cpu: 150_000_000),
        4010: usage(cpu: 250_000_000),
        5000: usage(cpu: 20_000_000),
        5050: usage(cpu: 1_180_000_000),
    ]

    static func grouped() -> [AppUsage] {
        var grouper = AppGrouper()
        return grouper.group(processes: processes, coalitions: coalitions, processDeltas: processDeltas)
    }
}

extension Array where Element == AppUsage {
    func app(named name: String) -> AppUsage? { first { $0.identity.name == name } }
}

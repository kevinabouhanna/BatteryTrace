import Attribution
import BatteryTraceCore
import Foundation
import Sampling

enum SourcesCommand {
    static func run(_ arguments: inout Arguments) {
        let pipeline = SamplingPipeline.standard()
        // A few ticks so IOReport can see which channels move.
        for _ in 0..<4 {
            _ = pipeline.tick(detailed: true)
            Thread.sleep(forTimeInterval: 1)
        }
        _ = pipeline.tick(detailed: true)
        print("Provider: \(pipeline.provider.providerName)")
        for source in pipeline.allSources {
            print("\n\(source.isAvailable ? "✓" : "✗") \(source.sourceName)")
            for line in source.diagnostics { print("    \(line)") }
        }
        if pipeline.live == nil { print("\n✗ live system power: unavailable") }
    }
}

enum SampleCommand {
    static func run(_ arguments: inout Arguments) {
        let interval = arguments.double("--interval", default: 5)
        let count = arguments.int("--count", default: 3)
        let top = arguments.int("--top", default: 12)
        let showProcesses = arguments.flag("--processes")
        let json = arguments.flag("--json")

        let pipeline = SamplingPipeline.standard()
        _ = pipeline.tick(detailed: true)
        var ledger = EnergyLedger()
        for index in 0..<count {
            Thread.sleep(forTimeInterval: interval)
            guard let report = pipeline.tick(detailed: true) else { continue }
            ledger.add(report)
            if let window = report.telemetry { ledger.add(window) }
            if json {
                print(JSONLine(report).encoded())
            } else {
                printReport(report, index: index + 1, top: top, processes: showProcesses)
            }
        }
        if !json, count > 1 {
            printSummary(ledger.summary(), top: top)
        }
    }

    static func printReport(_ report: IntervalReport, index: Int, top: Int, processes: Bool) {
        let seconds = report.durationSeconds
        func w(_ joules: Double) -> String { Format.watts(joules / seconds) }
        print("── interval \(index): \(String(format: "%.2f", seconds)) s, \(report.onExternalPower ? "on AC (power draw)" : "on battery (drain)") ──")
        if let measured = report.measuredJoules, let source = report.measuredSource {
            print("Measured total   \(w(measured))   (\(source.label))")
        } else {
            print("Measured total   unavailable")
        }
        if let window = report.telemetry {
            print("Battery gauge    \(Format.watts(window.systemLoadWatts)) average over the last \(Int(window.durationSeconds)) s")
        }
        print("Components       \(w(report.componentJoules))")
        for component in report.components {
            let mark = component.provenance == .estimated ? "  (estimate)" : ""
            print("  \(component.id.displayName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(w(component.joules))\(mark)")
        }
        if let unattributed = report.unattributedJoules {
            let share = report.measuredJoules.map { $0 > 0 ? unattributed / $0 * 100 : 0 } ?? 0
            print("  \("Unattributed".padding(toLength: 22, withPad: " ", startingAt: 0)) \(w(unattributed))  (\(String(format: "%.0f", share))% of measured)")
        }
        if report.overshootJoules > 0 { print("  components exceed measured by \(w(report.overshootJoules))") }
        print("Apps (estimated)  \(w(report.appJoules)) of CPU+GPU+ANE; unclaimed \(w(report.unclaimedJoules))")
        for app in report.apps.prefix(top) {
            let parts = [("cpu", app.cpuJoules), ("gpu", app.gpuJoules), ("ane", app.aneJoules)]
                .filter { $0.1 > 0 }.map { "\($0.0) \(w($0.1))" }.joined(separator: ", ")
            print("  \(Format.pad(app.identity.name, 34)) \(w(app.joules))   \(parts)")
            if processes {
                for process in app.processes.prefix(6) {
                    print("      \(Format.pad(process.name, 40)) \(w(process.cpuJoules))")
                }
            }
        }
        print("Battery Trace cost: \(String(format: "%.2f", Double(report.samplingCPUNS) / 1e6)) ms CPU for this tick")
        print("")
    }

    static func printSummary(_ summary: WindowSummary, top: Int) {
        print("══ whole run: \(String(format: "%.1f", summary.durationSeconds)) s ══")
        let basis: String = switch summary.basis {
        case .measured(let source): "measured by \(source.label)"
        case .componentsOnly: "components only (no measurement covered the run)"
        }
        print("Total            \(Format.watts(summary.averageWatts))   \(Format.energy(summary.totalJoules))   \(basis)")
        if let fraction = summary.unattributedFraction {
            print("Unattributed     \(String(format: "%.1f", fraction * 100))% of the total")
        }
        if summary.scale < 1 { print("Components scaled by \(String(format: "%.3f", summary.scale)) to fit the measured total") }
        for app in summary.apps.prefix(top) {
            print("  \(Format.pad(app.identity.name, 34)) \(String(format: "%5.1f", summary.share(of: app.joules) * 100))%   \(Format.energy(app.joules))")
        }
        print("  \(Format.pad("System / Unattributed", 34)) \(String(format: "%5.1f", summary.share(of: summary.systemJoules) * 100))%   \(Format.energy(summary.systemJoules))")
    }
}

/// One line of `sample --json`, for scripts and `compare-powermetrics`.
struct JSONLine: Codable {
    struct App: Codable {
        var name: String
        var key: String
        var bundleID: String?
        var coalitions: [UInt64]
        var watts: Double
        var cpuWatts: Double
        var gpuWatts: Double
        var aneWatts: Double
        var cpuTimeMsPerS: Double
    }

    var end: Date
    var seconds: Double
    var onAC: Bool
    var measuredWatts: Double?
    var measuredSource: String?
    var telemetryWatts: Double?
    var components: [String: Double]
    var unattributedWatts: Double?
    var apps: [App]
    var selfCPUms: Double

    init(_ report: IntervalReport) {
        let s = report.durationSeconds
        end = report.endDate
        seconds = s
        onAC = report.onExternalPower
        measuredWatts = report.measuredJoules.map { $0 / s }
        measuredSource = report.measuredSource.map { "\($0)" }
        telemetryWatts = report.telemetry?.systemLoadWatts
        components = Dictionary(uniqueKeysWithValues: report.components.map { ($0.id.rawValue, $0.joules / s) })
        unattributedWatts = report.unattributedJoules.map { $0 / s }
        apps = report.apps.map { app in
            App(name: app.identity.name, key: app.identity.key.rawValue, bundleID: app.identity.bundleID,
                coalitions: app.coalitionIDs, watts: app.joules / s, cpuWatts: app.cpuJoules / s,
                gpuWatts: app.gpuJoules / s, aneWatts: app.aneJoules / s,
                cpuTimeMsPerS: Double(app.usage.cpuTimeNS) / 1e6 / s)
        }
        selfCPUms = Double(report.samplingCPUNS) / 1e6
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

enum Format {
    static func watts(_ value: Double) -> String {
        value < 0.1 ? String(format: "%5.0f mW", value * 1000) : String(format: "%5.2f W ", value)
    }

    static func energy(_ joules: Double) -> String {
        let wh = joules / 3600
        return wh < 1 ? String(format: "%.1f mWh", wh * 1000) : String(format: "%.2f Wh", wh)
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count > width ? String(text.prefix(width - 1)) + "…" : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

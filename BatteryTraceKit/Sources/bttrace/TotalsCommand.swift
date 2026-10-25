import BatteryTraceCore
import Foundation
import Sampling

/// Checks the totals the way the engine samples: a live reading every few
/// seconds (integrated), attribution once a minute, and each minute set
/// against the battery gauge's own average for it.
enum TotalsCommand {
    static func run(_ arguments: inout Arguments) {
        let minutes = arguments.int("--minutes", default: 5)
        let live = arguments.double("--live", default: 2)
        let pipeline = SamplingPipeline.standard()
        pipeline.privileged?.usesHelper = arguments.flag("--helper")
        _ = pipeline.tick(detailed: false)
        print("minute  power    sensor  gauge   components  unattributed   CPU    display(est)")
        var rows: [(sensor: Double, gauge: Double?, components: Double)] = []
        for minute in 1...minutes {
            let start = Date()
            while Date().timeIntervalSince(start) < 60 - live / 2 {
                Thread.sleep(forTimeInterval: live)
                _ = pipeline.quickTick()
            }
            guard let report = pipeline.tick(detailed: false) else { continue }
            let s = report.durationSeconds
            let sensor = (report.measuredJoules ?? 0) / s
            let gauge = report.telemetry?.systemLoadWatts
            let components = report.componentJoules / s
            rows.append((sensor, gauge, components))
            let reference = gauge ?? sensor
            print(String(format: "%4d    %@  %5.2f W  %@  %5.2f W     %5.1f%%      %5.2f W  %5.2f W",
                         minute, report.onExternalPower ? "AC " : "bat", sensor,
                         gauge.map { String(format: "%5.2f W", $0) } ?? "   —   ", components,
                         reference > 0 ? (reference - components) / reference * 100 : 0,
                         (report.joules(for: .cpu) ?? 0) / s, (report.joules(for: .displayBacklight) ?? 0) / s))
        }
        let paired = rows.compactMap { row in row.gauge.map { (row.sensor, $0, row.components) } }
        guard !paired.isEmpty else { return }
        let n = Double(paired.count)
        let sensorMean = paired.reduce(0) { $0 + $1.0 } / n
        let gaugeMean = paired.reduce(0) { $0 + $1.1 } / n
        let componentMean = paired.reduce(0) { $0 + $1.2 } / n
        print(String(format: "\nOver %d gauge windows: sensor %.2f W, gauge %.2f W (sensor/gauge %.3f), components %.2f W",
                     paired.count, sensorMean, gaugeMean, sensorMean / gaugeMean, componentMean))
        print(String(format: "Average unattributed vs the gauge: %.1f%%", (gaugeMean - componentMean) / gaugeMean * 100))
    }
}

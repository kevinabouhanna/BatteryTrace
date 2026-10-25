import BatteryTraceCore
import Foundation
import Sampling

/// What sampling costs Battery Trace, stage by stage, and what that comes to
/// per minute under the engine's real cadence.
enum CostCommand {
    static func run(_ arguments: inout Arguments) {
        let interval = arguments.double("--interval", default: 2)
        let count = arguments.int("--count", default: 15)
        let detailed = arguments.flag("--detailed")
        let hot = arguments.flag("--hot")
        let warmup = arguments.int("--warmup", default: 8)
        let pipeline = SamplingPipeline.standard()
        if hot {
            // Back to back, for a profiler: `sample $(pgrep bttrace) 5`.
            print("pid \(getpid())")
            for _ in 0..<count { _ = pipeline.tick(detailed: detailed); usleep(20_000) }
            return
        }
        _ = pipeline.tick(detailed: detailed)
        for _ in 0..<warmup {
            Thread.sleep(forTimeInterval: min(interval, 1))
            _ = pipeline.tick(detailed: detailed)
        }

        var totals: [String: UInt64] = [:]
        var order: [String] = []
        var full: [Double] = []
        var quick: [Double] = []
        for _ in 0..<count {
            Thread.sleep(forTimeInterval: interval / 2)
            let start = Clock.threadCPUTimeNS()
            _ = pipeline.quickTick()
            quick.append(Double(Clock.threadCPUTimeNS() - start) / 1e6)
            Thread.sleep(forTimeInterval: interval / 2)
            guard let report = pipeline.tick(detailed: detailed) else { continue }
            full.append(Double(report.samplingCPUNS) / 1e6)
            var stages = pipeline.lastTimings
            if let metrics = pipeline.unprivileged {
                stages = stages.filter { $0.stage != "provider" }.map { ("  " + $0.stage, $0.ns) } + metrics.lastTimings.map { ("provider: " + $0.stage, $0.ns) }
            }
            for (stage, ns) in stages {
                if totals[stage] == nil { order.append(stage) }
                totals[stage, default: 0] += ns
            }
        }

        if let metrics = pipeline.unprivileged {
            print("Coalitions read on the last tick: \(metrics.lastCoalitionReads.read) of \(metrics.lastCoalitionReads.wanted)")
            for source in metrics.componentSources { print("\(source.sourceName): " + source.diagnostics.joined(separator: "; ")) }
        }
        let n = Double(max(1, full.count))
        print("\nFull (attribution) tick, mean of \(full.count) after \(warmup) warm-up ticks, \(detailed ? "with" : "without") popover detail:")
        for stage in order { print(String(format: "  %-34@ %7.3f ms", stage as NSString, Double(totals[stage]!) / 1e6 / n)) }
        let fullMean = full.reduce(0, +) / n
        let quickMean = quick.reduce(0, +) / Double(max(1, quick.count))
        print(String(format: "  %-34@ %7.3f ms  (max %.3f)", "whole full tick" as NSString, fullMean, full.max() ?? 0))
        print(String(format: "Quick (live) tick: %.3f ms  (max %.3f)", quickMean, quick.max() ?? 0))

        let policy = SamplingPolicy()
        print("\nProjected sampling CPU, as the engine schedules it:")
        for (label, conditions) in [("popover closed", SamplingPolicy.Conditions()),
                                    ("popover closed, Low Power Mode", SamplingPolicy.Conditions(lowPowerMode: true)),
                                    ("popover open", SamplingPolicy.Conditions(popoverVisible: true))] {
            guard let schedule = policy.schedule(for: conditions) else { continue }
            let perMinuteFires = 60 / schedule.interval
            let fullPerMinute = perMinuteFires / Double(schedule.attributeEvery)
            let ms = fullPerMinute * fullMean + (perMinuteFires - fullPerMinute) * quickMean
            print(String(format: "  %-32@ %6.1f ms CPU per minute = %.3f%% of one core", label as NSString, ms, ms / 600))
        }

        var info = mach_task_basic_info()
        var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size) } }
        var usage = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        print(String(format: "\nbttrace itself: resident %.1f MB, footprint %.1f MB", Double(info.resident_size) / 1048576, Double(usage.ri_phys_footprint) / 1048576))
    }
}

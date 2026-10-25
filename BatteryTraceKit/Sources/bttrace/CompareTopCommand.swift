import Attribution
import BatteryTraceCore
import Foundation
import Sampling

/// Ranks apps both ways over the same seconds: Battery Trace's estimate,
/// and `top`'s POWER column, which is the "Energy Impact" score Activity
/// Monitor shows. `top` needs no root, so this runs anywhere.
///
/// Energy Impact is a unitless weighting of CPU time, wakeups and GPU time,
/// not energy. Agreement in *ranking* is the test, not equal numbers.
enum CompareTopCommand {
    static func run(_ arguments: inout Arguments) {
        let interval = arguments.double("--interval", default: 5)
        let count = arguments.int("--count", default: 3)
        let shown = arguments.int("--top", default: 15)
        let label = arguments.value("--label") ?? "run"

        let pipeline = SamplingPipeline.standard()
        pipeline.keepsProcessTable = true
        _ = pipeline.tick(detailed: false)

        // top's first sample has no delta; ask for one extra and drop it.
        let top = Process()
        top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        top.arguments = ["-l", "\(count + 1)", "-s", "\(Int(interval))", "-stats", "pid,power,command", "-n", "1000"]
        let pipe = Pipe()
        top.standardOutput = pipe
        try? top.run()

        var ledger = EnergyLedger()
        var appOfPID: [Int32: AppKey] = [:]
        var names: [AppKey: String] = [:]
        for _ in 0..<count {
            Thread.sleep(forTimeInterval: interval)
            guard let report = pipeline.tick(detailed: false) else { continue }
            ledger.add(report)
            var appOfCoalition: [UInt64: AppKey] = [:]
            for app in report.apps {
                names[app.identity.key] = app.identity.name
                for id in app.coalitionIDs { appOfCoalition[id] = app.identity.key }
            }
            for process in pipeline.lastProcesses {
                if let key = appOfCoalition[process.coalitionID] { appOfPID[process.pid] = key }
            }
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        top.waitUntilExit()

        // Sum top's POWER per app, skipping its first (delta-less) sample.
        var topPower: [AppKey: Double] = [:]
        var unmatched = 0.0
        var sample = 0
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("PID") { sample += 1; continue }
            guard sample >= 2 else { continue }
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]), let power = Double(fields[1]) else { continue }
            if let key = appOfPID[pid] { topPower[key, default: 0] += power } else { unmatched += power }
        }

        let summary = ledger.summary()
        let ours = Dictionary(summary.apps.map { ($0.identity.key, $0.joules) }, uniquingKeysWith: +)
        let candidates = Set(ours.sorted { $0.value > $1.value }.prefix(shown).map(\.key))
            .union(topPower.sorted { $0.value > $1.value }.prefix(shown).map(\.key))
        let keys = Array(candidates)
        let x = keys.map { ours[$0] ?? 0 }
        let y = keys.map { topPower[$0] ?? 0 }

        print("── \(label): \(count) × \(Int(interval)) s, Battery Trace vs top POWER (Energy Impact) ──")
        print("\(Format.pad("App", 34)) \(Format.pad("Battery Trace", 16)) top POWER")
        for key in keys.sorted(by: { (ours[$0] ?? 0) > (ours[$1] ?? 0) }) {
            let watts = (ours[key] ?? 0) / max(1, summary.durationSeconds)
            print("\(Format.pad(names[key] ?? key.rawValue, 34)) \(Format.pad(Format.watts(watts), 16)) \(String(format: "%7.1f", (topPower[key] ?? 0) / Double(count)))")
        }
        print(String(format: "Spearman rank correlation over %d apps: %.2f", keys.count, Statistics.spearman(x, y)))
        print(Statistics.headline(keys: keys, ours: ours, theirs: topPower))
        print(String(format: "Pearson correlation of the values:      %.2f", Statistics.pearson(x, y)))
        let topTotal = topPower.values.reduce(0, +) + unmatched
        if topTotal > 0 { print(String(format: "top POWER not matched to an app (processes that came and went): %.0f%%", unmatched / topTotal * 100)) }
        if let fraction = summary.unattributedFraction { print(String(format: "Unattributed share of the measured total: %.0f%%", fraction * 100)) }
    }
}

enum Statistics {
    static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, values[order[j + 1]] == values[order[i]] { j += 1 }
            let rank = Double(i + j) / 2 + 1
            for k in i...j { ranks[order[k]] = rank }
            i = j + 1
        }
        return ranks
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 1 else { return .nan }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
            syy += (y[i] - my) * (y[i] - my)
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : .nan
    }

    static func spearman(_ x: [Double], _ y: [Double]) -> Double { pearson(ranks(x), ranks(y)) }

    /// Rank agreement where it matters: the apps a person would actually
    /// look at. Below a few milliwatts, both tools' ranks are mostly noise.
    static func headline<K: Hashable>(keys: [K], ours: [K: Double], theirs: [K: Double], top n: Int = 8) -> String {
        let leaders = Array(keys.sorted { (ours[$0] ?? 0) > (ours[$1] ?? 0) }.prefix(n))
        let rho = spearman(leaders.map { ours[$0] ?? 0 }, leaders.map { theirs[$0] ?? 0 })
        let ourTop5 = Set(keys.sorted { (ours[$0] ?? 0) > (ours[$1] ?? 0) }.prefix(5))
        let theirTop5 = Set(keys.sorted { (theirs[$0] ?? 0) > (theirs[$1] ?? 0) }.prefix(5))
        return String(format: "Spearman over our top %d: %.2f   Top-5 overlap: %d of 5", leaders.count, rho, ourTop5.intersection(theirTop5).count)
    }
}

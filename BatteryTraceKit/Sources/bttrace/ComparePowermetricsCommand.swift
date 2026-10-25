import Foundation

/// Compares a `bttrace sample --json` run with a `powermetrics -f plist` run
/// over the same seconds.
///
/// Apps are joined on kernel coalition ID, which both tools report, then on
/// name. powermetrics gives per-coalition Energy Impact and CPU/GPU time, not
/// watts, so the per-app test is rank correlation; the component test (CPU,
/// GPU, ANE watts) compares values directly.
enum ComparePowermetricsCommand {
    static func run(_ arguments: inout Arguments) {
        guard let oursPath = arguments.value("--ours"), let pmPath = arguments.value("--powermetrics") else {
            print("usage: bttrace compare-powermetrics --ours sample.jsonl --powermetrics pm.plist [--label NAME] [--top 15]")
            return
        }
        let label = arguments.value("--label") ?? URL(fileURLWithPath: pmPath).deletingPathExtension().lastPathComponent
        let shown = arguments.int("--top", default: 15)

        guard let ours = loadOurs(oursPath), !ours.isEmpty else { print("no intervals in \(oursPath)"); return }
        guard let pm = loadPowermetrics(pmPath), !pm.samples.isEmpty else { print("no samples in \(pmPath)"); return }

        // Ours: mean watts per app over the run.
        let seconds = ours.reduce(0) { $0 + $1.seconds }
        var ourWatts: [String: Double] = [:]
        var ourName: [String: String] = [:]
        var coalitionToApp: [UInt64: String] = [:]
        var nameToApp: [String: String] = [:]
        var components: [String: Double] = [:]
        for line in ours {
            for app in line.apps {
                ourWatts[app.key, default: 0] += app.watts * line.seconds / seconds
                ourName[app.key] = app.name
                for id in app.coalitions { coalitionToApp[id] = app.key }
                nameToApp[app.name.lowercased()] = app.key
                if let bundle = app.bundleID { nameToApp[bundle.lowercased()] = app.key }
            }
            for (id, watts) in line.components { components[id, default: 0] += watts * line.seconds / seconds }
        }

        // powermetrics: mean Energy Impact and CPU/GPU time per coalition, mapped to our apps.
        var impact: [String: Double] = [:]
        var cpuMs: [String: Double] = [:]
        var gpuMs: [String: Double] = [:]
        var unmatchedImpact = 0.0
        var unmatchedNames: [String: Double] = [:]
        let n = Double(pm.samples.count)
        for sample in pm.samples {
            for coalition in sample.coalitions {
                let key = coalition.id.flatMap { coalitionToApp[$0] } ?? nameToApp[coalition.name.lowercased()]
                guard let key else {
                    unmatchedImpact += coalition.energyImpact / n
                    unmatchedNames[coalition.name, default: 0] += coalition.energyImpact / n
                    continue
                }
                impact[key, default: 0] += coalition.energyImpact / n
                cpuMs[key, default: 0] += coalition.cpuMsPerS / n
                gpuMs[key, default: 0] += coalition.gpuMsPerS / n
            }
        }

        let keys = Array(Set(ourWatts.sorted { $0.value > $1.value }.prefix(shown).map(\.key))
            .union(impact.sorted { $0.value > $1.value }.prefix(shown).map(\.key)))
        print("── \(label): \(ours.count) intervals (\(Int(seconds)) s) vs \(pm.samples.count) powermetrics samples ──")
        print("\(Format.pad("App", 30)) \(Format.pad("Battery Trace", 13)) \(Format.pad("PM impact/s", 12)) \(Format.pad("PM CPU ms/s", 12)) PM GPU ms/s")
        for key in keys.sorted(by: { (ourWatts[$0] ?? 0) > (ourWatts[$1] ?? 0) }) {
            print("\(Format.pad(ourName[key] ?? key, 30)) \(Format.pad(Format.watts(ourWatts[key] ?? 0), 13)) "
                + String(format: "%11.1f  %11.1f  %10.1f", impact[key] ?? 0, cpuMs[key] ?? 0, gpuMs[key] ?? 0))
        }
        let x = keys.map { ourWatts[$0] ?? 0 }
        print(String(format: "Spearman, Battery Trace vs Energy Impact: %.2f   Pearson %.2f   (%d apps)",
                     Statistics.spearman(x, keys.map { impact[$0] ?? 0 }), Statistics.pearson(x, keys.map { impact[$0] ?? 0 }), keys.count))
        print(Statistics.headline(keys: keys, ours: ourWatts, theirs: impact))
        print(String(format: "Spearman, Battery Trace vs CPU+GPU time:  %.2f",
                     Statistics.spearman(x, keys.map { (cpuMs[$0] ?? 0) + (gpuMs[$0] ?? 0) })))
        let totalImpact = impact.values.reduce(0, +) + unmatchedImpact
        if totalImpact > 0 {
            let top = unmatchedNames.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \(String(format: "%.1f", $0.value))" }
            print(String(format: "Energy Impact on coalitions we didn't match: %.0f%%", unmatchedImpact / totalImpact * 100)
                + (top.isEmpty ? "" : " (\(top.joined(separator: ", ")))"))
        }

        print("\nComponents (mean watts)       Battery Trace   powermetrics")
        for (id, name) in [("cpu", "CPU"), ("gpu", "GPU"), ("ane", "ANE")] {
            let theirs = pm.samples.compactMap { $0.componentWatts[id] }
            let theirMean = theirs.isEmpty ? nil : theirs.reduce(0, +) / Double(theirs.count)
            print("  \(Format.pad(name, 28)) \(Format.pad(Format.watts(components[id] ?? 0), 15)) \(theirMean.map(Format.watts) ?? "  n/a")"
                + (theirMean.flatMap { $0 > 0.01 ? String(format: "   ratio %.2f", (components[id] ?? 0) / $0) : nil } ?? ""))
        }
        if !pm.keysSeen.isEmpty { print("\n(powermetrics processor keys seen: \(pm.keysSeen.sorted().joined(separator: ", ")))") }
    }

    // MARK: Loading

    private static func loadOurs(_ path: String) -> [JSONLine]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(JSONLine.self, from: Data($0.utf8)) }
    }

    struct PMCoalition {
        var id: UInt64?
        var name: String
        var energyImpact: Double
        var cpuMsPerS: Double
        var gpuMsPerS: Double
    }

    struct PMSample {
        var seconds: Double
        var coalitions: [PMCoalition]
        var componentWatts: [String: Double]
    }

    /// `powermetrics -f plist` writes one plist per sample, separated by NULs.
    private static func loadPowermetrics(_ path: String) -> (samples: [PMSample], keysSeen: Set<String>)? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var samples: [PMSample] = []
        var keysSeen = Set<String>()
        for chunk in data.split(separator: 0) where !chunk.isEmpty {
            guard let plist = try? PropertyListSerialization.propertyList(from: Data(chunk), format: nil) as? [String: Any] else { continue }
            let seconds = (plist["elapsed_ns"] as? NSNumber).map { $0.doubleValue / 1e9 } ?? 5
            func number(_ dict: [String: Any], _ keys: [String]) -> Double? {
                for key in keys { if let value = dict[key] as? NSNumber { return value.doubleValue } }
                return nil
            }
            let entries = (plist["coalitions"] as? [[String: Any]]) ?? (plist["tasks"] as? [[String: Any]]) ?? []
            let coalitions = entries.map { entry in
                PMCoalition(
                    id: (entry["id"] as? NSNumber)?.uint64Value,
                    name: entry["name"] as? String ?? "?",
                    energyImpact: number(entry, ["energy_impact_per_s"]) ?? (number(entry, ["energy_impact"]).map { $0 / seconds } ?? 0),
                    cpuMsPerS: number(entry, ["cputime_ms_per_s"]) ?? 0,
                    gpuMsPerS: number(entry, ["gputime_ms_per_s"]) ?? 0
                )
            }
            var watts: [String: Double] = [:]
            let processor = plist["processor"] as? [String: Any] ?? [:]
            let gpu = plist["gpu"] as? [String: Any] ?? [:]
            keysSeen.formUnion(processor.keys.filter { $0.contains("power") || $0.contains("energy") })
            for (id, dict) in [("cpu", processor), ("gpu", processor), ("ane", processor), ("gpu", gpu)] where watts[id] == nil {
                if let mW = number(dict, ["\(id)_power"]) {
                    watts[id] = mW / 1000
                } else if let mJ = number(dict, ["\(id)_energy"]) {
                    watts[id] = mJ / 1000 / seconds
                }
            }
            samples.append(PMSample(seconds: seconds, coalitions: coalitions, componentWatts: watts))
        }
        return (samples, keysSeen)
    }
}

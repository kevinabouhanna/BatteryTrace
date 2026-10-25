import Attribution
import BatteryTraceCore
import Foundation
import Storage

/// The history store on its own serial queue. Recording is in memory and
/// returns at once; the store writes to disk every few minutes.
final class HistoryService: @unchecked Sendable {
    // `store` is touched only on `queue`.
    private let queue = DispatchQueue(label: "app.batterytrace.history", qos: .utility)
    private var store: HistoryStore?

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Battery Trace", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    init(url: URL) {
        queue.async {
            do {
                self.store = try HistoryStore(url: url)
            } catch {
                NSLog("Battery Trace: history unavailable: \(error)")
            }
        }
    }

    func record(_ reading: LiveReading) {
        queue.async { self.store?.record(reading) }
    }

    func record(_ report: IntervalReport) {
        queue.async {
            self.store?.record(report)
            self.store?.flushIfDue()
        }
    }

    /// Before sleep and on quit, so nothing buffered is lost.
    func flushNow() {
        queue.sync { try? self.store?.flush() }
    }

    func flushSoon() {
        queue.async { try? self.store?.flush() }
    }

    /// Writes the history as two CSV files into `directory`; the URLs, or an
    /// error, on the main queue.
    func exportCSV(to directory: URL, completion: @escaping @Sendable (Result<[URL], Error>) -> Void) {
        queue.async {
            let result = Result<[URL], Error> {
                guard let store = self.store else { throw CocoaError(.fileNoSuchFile) }
                let export = try store.exportCSV(since: Date().addingTimeInterval(-7 * 86400))
                let day = Date().formatted(.iso8601.year().month().day())
                let apps = directory.appendingPathComponent("Battery Trace apps \(day).csv")
                let system = directory.appendingPathComponent("Battery Trace system \(day).csv")
                try export.apps.write(to: apps, atomically: true, encoding: .utf8)
                try export.system.write(to: system, atomically: true, encoding: .utf8)
                return [apps, system]
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    struct BatteryHistory: Sendable {
        var points: [ChargePoint]
        var summary: ChargeSummary
        var health: [HealthPoint]
    }

    /// Charge since `start` (thinned to about `points` for drawing, summed
    /// from every minute) and the daily health readings, on the main queue.
    func batteryHistory(since start: Date, points: Int = 300, completion: @escaping @Sendable (BatteryHistory?) -> Void) {
        queue.async {
            guard let store = self.store, let charge = try? store.chargeHistory(since: start) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let step = max(1, charge.count / points)
            // Keep each kept point's charging and adapter state as the
            // bucket's, so short charges don't vanish from the chart.
            var thinned: [ChargePoint] = []
            var index = 0
            while index < charge.count {
                let bucket = charge[index..<min(charge.count, index + step)]
                var point = bucket.last!
                point.charging = bucket.contains { $0.charging }
                point.onExternalPower = bucket.contains { $0.onExternalPower }
                thinned.append(point)
                index += step
            }
            let history = BatteryHistory(points: thinned, summary: HistoryStore.summarize(charge),
                                         health: (try? store.healthHistory()) ?? [])
            DispatchQueue.main.async { completion(history) }
        }
    }

    /// The window's totals, delivered on the main queue.
    func summary(since start: Date, completion: @escaping @Sendable (WindowSummary?) -> Void) {
        queue.async {
            let summary = try? self.store?.ledger(since: start).summary()
            DispatchQueue.main.async { completion(summary) }
        }
    }

    /// Total watts and per-component watts for sparklines, at most `points`
    /// values each, delivered on the main queue.
    func sparklines(since start: Date, components: [ComponentID], points: Int = 60,
                    completion: @escaping @Sendable ([Double], [ComponentID: [Double]]) -> Void) {
        queue.async {
            let total = (try? self.store?.liveSeries(since: start).map(\.watts)) ?? []
            var series: [ComponentID: [Double]] = [:]
            for id in components {
                series[id] = (try? self.store?.componentSeries(id, since: start).map(\.watts)) ?? []
            }
            let reduced = Self.downsample(total, to: points)
            DispatchQueue.main.async { completion(reduced, series) }
        }
    }

    /// Averages consecutive values so a series has at most `count` points.
    static func downsample(_ values: [Double], to count: Int) -> [Double] {
        guard values.count > count, count > 0 else { return values }
        let size = Double(values.count) / Double(count)
        return (0..<count).map { i in
            let slice = values[Int(Double(i) * size)..<min(values.count, Int(Double(i + 1) * size))]
            return slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
        }
    }
}

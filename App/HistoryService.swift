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

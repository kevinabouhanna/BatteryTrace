import BatteryTraceCore
import Foundation

/// History as two CSV files, for spreadsheets.
public struct CSVExport: Sendable {
    /// Per app: minutes for the last day, hours before that.
    public let apps: String
    /// Per minute: totals, components, Unattributed, battery.
    public let system: String
}

extension HistoryStore {
    /// Everything stored since `start`, buffered data included.
    public func exportCSV(since start: Date, now: Date = Date()) throws -> CSVExport {
        try flush(now: now)
        let from = Self.minute(of: start)
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime]
        time.timeZone = .current
        func stamp(_ seconds: Int64) -> String { time.string(from: Date(timeIntervalSince1970: Double(seconds))) }
        func wh(_ joules: Double) -> String { String(format: "%.6f", joules / 3600) }

        // Apps, oldest first, the biggest first within a period.
        var appRows: [(start: Int64, total: Double, line: String)] = []
        let appQuery = """
        SELECT ts, 1, a.name, a.bundle_id, a.kind, cpu_j, gpu_j, ane_j FROM minute_app m JOIN apps a ON a.id = m.app WHERE ts >= ?
        UNION ALL
        SELECT ts, 60, a.name, a.bundle_id, a.kind, cpu_j, gpu_j, ane_j FROM hour_app h JOIN apps a ON a.id = h.app
            WHERE ts >= ? AND ts < (SELECT coalesce(min(ts), ?) FROM minute_app)
        """
        try db.statement(appQuery).bind(from, (from / 3600) * 3600, Int64(now.timeIntervalSince1970)).rows { row in
            let cpu = row.double(5), gpu = row.double(6), ane = row.double(7)
            let kind = AppKind(rawValue: UInt8(row.int(4))).map(Self.label) ?? "other"
            appRows.append((row.int(0), cpu + gpu + ane,
                            [stamp(row.int(0)), String(row.int(1)), Self.field(row.string(2) ?? ""), Self.field(row.string(3) ?? ""),
                             kind, wh(cpu), wh(gpu), wh(ane), wh(cpu + gpu + ane)].joined(separator: ",")))
        }
        appRows.sort { $0.start == $1.start ? $0.total > $1.total : $0.start < $1.start }
        let apps = ["start,resolution_minutes,app,bundle_id,kind,cpu_wh,gpu_wh,ane_wh,total_wh"] + appRows.map(\.line)

        // System, one row per minute, components pivoted into columns.
        let columns: [(ComponentID, String)] = [
            (.cpu, "cpu_wh"), (.gpu, "gpu_wh"), (.ane, "ane_wh"), (.memory, "memory_wh"),
            (.displayBacklight, "display_backlight_wh_estimate"), (.displayController, "display_controller_wh"),
            (.otherSoC, "other_chip_wh"), (.pcie, "pcie_wh"),
        ]
        var components: [Int64: [String: Double]] = [:]
        try db.statement("SELECT ts, component, joules FROM minute_component WHERE ts >= ?").bind(from).rows { row in
            if let id = row.string(1) { components[row.int(0), default: [:]][id] = row.double(2) }
        }
        var system = ["start,seconds,on_battery_seconds,measured_wh,measured_by,battery_gauge_wh,"
            + columns.map(\.1).joined(separator: ",") + ",unattributed_wh,battery_percent,on_power_adapter"]
        try db.statement("""
        SELECT ts, seconds, battery_seconds, sensor_j, sensor_seconds, sensor_src, telemetry_j, telemetry_seconds, battery_pct, on_ac
        FROM minute WHERE ts >= ? ORDER BY ts
        """).bind(from).rows { row in
            let seconds = row.double(1)
            let sensorSeconds = row.double(4)
            // The sensor's energy, scaled to the whole minute when it covered most of it.
            let measured: Double? = sensorSeconds >= seconds * 0.8 && sensorSeconds > 0 ? row.double(3) * seconds / sensorSeconds : nil
            let source = row.isNull(5) ? "" : (TotalSource(rawValue: UInt8(row.int(5))).map { $0.label } ?? "")
            let parts = components[row.int(0)] ?? [:]
            let componentTotal = parts.values.reduce(0, +)
            var fields = [stamp(row.int(0)), String(format: "%.1f", seconds), String(format: "%.1f", row.double(2)),
                          measured.map(wh) ?? "", Self.field(measured == nil ? "" : source),
                          row.double(7) > 0 ? wh(row.double(6)) : ""]
            fields += columns.map { parts[$0.0.rawValue].map(wh) ?? "" }
            fields.append(measured.map { wh(max(0, $0 - componentTotal)) } ?? "")
            fields.append(row.isNull(8) ? "" : String(format: "%.0f", row.double(8)))
            fields.append(row.int(9) == 1 ? "yes" : "no")
            system.append(fields.joined(separator: ","))
        }
        return CSVExport(apps: apps.joined(separator: "\n") + "\n", system: system.joined(separator: "\n") + "\n")
    }

    /// RFC 4180: quoted when it holds a comma, quote or line break.
    static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func label(_ kind: AppKind) -> String {
        switch kind {
        case .app: "app"
        case .system: "system"
        case .kernel: "kernel"
        case .other: "other"
        }
    }
}

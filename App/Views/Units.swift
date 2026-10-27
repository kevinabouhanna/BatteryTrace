import BatteryTraceCore
import Foundation

/// How numbers are written. Estimates get a leading "≈".
enum Units {
    static func watts(_ value: Double, estimated: Bool = false) -> String {
        let prefix = estimated ? "≈ " : ""
        if value < 0.0005 { return prefix + "0 mW" }
        if value < 1 { return prefix + String(format: "%.0f mW", value * 1000) }
        return prefix + String(format: value < 10 ? "%.2f W" : "%.1f W", value)
    }

    static func menuBarWatts(_ value: Double) -> String {
        String(format: value < 10 ? "%.1f W" : "%.0f W", value)
    }

    static func energy(_ joules: Double, estimated: Bool = false) -> String {
        let prefix = estimated ? "≈ " : ""
        let wh = joules / 3600
        if wh < 0.0005 { return prefix + "0 mWh" }
        if wh < 0.01 { return prefix + String(format: "%.1f mWh", wh * 1000) }
        if wh < 1 { return prefix + String(format: "%.0f mWh", wh * 1000) }
        return prefix + String(format: "%.2f Wh", wh)
    }

    /// A change in percentage points, signed. One that rounds to zero is "No
    /// change", never "-0.0".
    static func points(_ change: Double) -> String {
        let rounded = (change * 10).rounded() / 10
        if rounded == 0 { return "No change" }
        return String(format: "%+.1f points", rounded)
    }

    static func share(_ fraction: Double) -> String {
        if fraction <= 0 { return "0%" }
        if fraction < 0.01 { return "<1%" }
        return String(format: "%.0f%%", fraction * 100)
    }

    static func duration(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func span(seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds)) s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        return String(format: "%.1f h", seconds / 3600)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func tooltip(for reading: LiveReading) -> String {
        var parts: [String] = []
        if let watts = reading.systemWatts {
            parts.append(reading.battery.isOnExternalPower ? "Power draw \(Self.watts(watts))" : "Using \(Self.watts(watts)) from the battery")
        }
        if let percent = reading.battery.percent { parts.append("Battery \(Int(percent.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}

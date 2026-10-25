import BatteryTraceCore
import SwiftUI

/// Battery %, charging state, live watts, time remaining.
struct SummarySection: View {
    let reading: LiveReading?
    /// The live total, smoothed over the last few readings.
    let watts: Double?
    /// Total watts over the last hour, for the sparkline.
    let series: [Double]

    private var battery: BatterySnapshot { reading?.battery ?? BatterySnapshot() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let percent = battery.percent {
                    Image(systemName: batterySymbol(percent))
                        .font(.title2)
                        .foregroundStyle(battery.isCharging ? .green : .primary)
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Image(systemName: "powerplug.fill").font(.title2)
                    Text("No battery").font(.title3.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(watts.map { Units.watts($0) } ?? "–")
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                    Text(powerCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(stateLine)
                .font(.callout)
                .foregroundStyle(.secondary)

            if series.count >= 2 {
                Sparkline(values: series)
                    .frame(height: 22)
                    .accessibilityLabel("Total power over the last hour")
            }

            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var powerCaption: String {
        guard battery.isPresent else { return "power draw" }
        return battery.isOnExternalPower ? "power draw, not from battery" : "from the battery"
    }

    private var stateLine: String {
        guard battery.isPresent else { return "Measured at the power input." }
        if battery.isOnExternalPower {
            if battery.isCharging {
                return battery.minutesToFull.map { "Charging · \(Units.duration(minutes: $0)) to full" } ?? "Charging"
            }
            return battery.isFullyCharged ? "On power adapter · fully charged" : "On power adapter · not charging"
        }
        return battery.minutesToEmpty.map { "On battery · about \(Units.duration(minutes: $0)) remaining" } ?? "On battery · estimating time remaining"
    }

    private var details: String {
        var parts: [String] = []
        if let health = battery.healthPercent { parts.append(String(format: "Health %.0f%%", health)) }
        if let cycles = battery.cycleCount { parts.append("\(cycles) cycles") }
        if let temperature = battery.temperatureC { parts.append(String(format: "%.0f °C", temperature)) }
        return parts.joined(separator: " · ")
    }

    private func batterySymbol(_ percent: Double) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

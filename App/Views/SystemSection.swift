import BatteryTraceCore
import SwiftUI

/// What isn't an app: components, CPU load, memory, display, thermal state.
struct SystemSection: View {
    let report: IntervalReport?
    /// Watts per minute over the last hour, per component.
    let series: [ComponentID: [Double]]

    static let sparklineComponents: [ComponentID] = [.cpu, .gpu, .ane, .memory, .displayBacklight, .displayController, .otherSoC]

    var body: some View {
        ScrollView {
            if let report {
                VStack(alignment: .leading, spacing: 10) {
                    components(report)
                    Divider()
                    details(report.system)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            } else {
                Text("Measuring…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxHeight: 340)
    }

    @ViewBuilder
    private func components(_ report: IntervalReport) -> some View {
        let seconds = max(report.durationSeconds, 0.001)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("last hour").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(report.components, id: \.id) { component in
                ComponentRow(
                    name: component.id.displayName,
                    watts: component.joules / seconds,
                    estimated: component.provenance == .estimated,
                    caption: caption(for: component.id, report: report),
                    series: series[component.id] ?? []
                )
            }
            if let unattributed = report.unattributedJoules {
                ComponentRow(name: "Unattributed", watts: unattributed / seconds, estimated: false,
                             caption: "Wi-Fi, SSD, audio, panel electronics, conversion losses", series: [])
            }
            if let measured = report.measuredJoules {
                HStack {
                    Text("Measured total").font(.callout.weight(.medium))
                    Spacer()
                    Text(Units.watts(measured / seconds)).monospacedDigit()
                }
            }
        }
    }

    private func caption(for id: ComponentID, report: IntervalReport) -> String? {
        let system = report.system
        switch id {
        case .displayBacklight:
            var parts: [String] = []
            if let brightness = system.display.brightness { parts.append(String(format: "Brightness %.0f%%", brightness * 100)) }
            parts.append(system.display.calibratedOnThisMac ? "calibrated here" : "not calibrated")
            if DisplayConditions.builtInShowsHDR { parts.append("HDR on: may read low") }
            return parts.joined(separator: " · ")
        case .cpu:
            var parts: [String] = []
            if !system.cpuLoad.perCore.isEmpty {
                parts.append(String(format: "Load %.0f%% across %d cores", system.cpuLoad.average * 100, system.cpuLoad.perCore.count))
            }
            if report.cpuFromPowermetrics { parts.append("from powermetrics") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .memory:
            return "DRAM and its controller"
        case .displayController:
            return DisplayConditions.hasExternalDisplay
                ? "The chip's display pipes. An external display powers itself; only this side counts."
                : "The chip's display pipes"
        case .otherSoC:
            return "Video codecs, image processor, always-on blocks"
        default:
            return nil
        }
    }

    @ViewBuilder
    private func details(_ system: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !system.cpuLoad.perCore.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPU load per core").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    CoreBars(load: system.cpuLoad.perCore)
                }
            }
            if system.memory.totalBytes > 0 {
                DetailRow(label: "Memory used", value: "\(Units.bytes(system.memory.usedBytes)) of \(Units.bytes(system.memory.totalBytes))")
                DetailRow(label: "Compressed · swap", value: "\(Units.bytes(system.memory.compressedBytes)) · \(Units.bytes(system.memory.swapUsedBytes))")
                DetailRow(label: "Memory pressure", value: pressure(system.memory.pressure))
            }
            DetailRow(label: "Thermal state", value: system.thermal.label)
            if system.lowPowerMode { DetailRow(label: "Low Power Mode", value: "On (sampling slower)") }
        }
    }

    private func pressure(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

struct ComponentRow: View {
    let name: String
    let watts: Double
    let estimated: Bool
    let caption: String?
    let series: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).lineLimit(1).fixedSize()
                    if estimated {
                        Text("estimate").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                }
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if series.count >= 2 {
                Sparkline(values: series).frame(width: 56, height: 16)
            }
            Text(Units.watts(watts, estimated: estimated))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

struct CoreBars: View {
    let load: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(load.indices, id: \.self) { i in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(height: max(1, 18 * load[i]))
                }
                .frame(width: 10, height: 18)
            }
        }
        .accessibilityLabel(String(format: "Average load %.0f percent", load.reduce(0, +) / Double(max(1, load.count)) * 100))
    }
}

/// What the screens are doing, read when the System tab is drawn.
@MainActor
enum DisplayConditions {
    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }

    /// HDR content is showing on the built-in screen: the panel can draw
    /// more than the brightness model expects.
    static var builtInShowsHDR: Bool {
        NSScreen.screens.contains { isBuiltIn($0) && $0.maximumExtendedDynamicRangeColorComponentValue > 1.0 }
    }

    static var hasExternalDisplay: Bool { NSScreen.screens.contains { !isBuiltIn($0) } }
}

import BatteryTraceCore
import Storage
import SwiftUI

/// How the battery has been used, and how it's ageing.
struct BatterySection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Period", selection: $model.batteryWindow) {
                ForEach(BatteryWindow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let history = model.battery, history.points.count >= 2 {
                ChargeChart(points: history.points, start: Date().addingTimeInterval(-model.batteryWindow.seconds), end: Date())
                    .frame(height: 96)
                HStack(spacing: 12) {
                    Legend(color: .green.opacity(0.35), label: "Charging")
                    Legend(color: .secondary.opacity(0.35), label: "On power adapter")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                usage(history.summary)
            } else {
                Text(model.battery == nil ? "Loading…" : "Charge history appears here as it's recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
            }

            Divider()
            health(model.battery?.health ?? [], current: model.reading?.battery)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func usage(_ summary: ChargeSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailRow(label: "On battery", value: Units.span(seconds: summary.onBatterySeconds))
            DetailRow(label: "Used on battery", value: String(format: "%.0f%% of a full charge", summary.percentUsedOnBattery))
            DetailRow(label: "Charged", value: summary.chargeSessions == 1 ? "once" : "\(summary.chargeSessions) times")
        }
    }

    @ViewBuilder
    private func health(_ points: [HealthPoint], current: BatterySnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Health").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let macOS = current?.macOSMaximumCapacityPercent ?? points.last?.macOSPercent {
                DetailRow(label: "Maximum capacity", value: "\(macOS)%")
            } else if let gauge = current?.gaugeCapacityPercent ?? points.last?.gaugePercent {
                DetailRow(label: "Maximum capacity", value: String(format: "%.1f%% of new", gauge))
            }
            if let nominal = current?.nominalCapacityMAh, let design = current?.designCapacityMAh {
                DetailRow(label: "Holds when full", value: "\(nominal.formatted()) of \(design.formatted()) mAh")
                if let macOS = current?.macOSMaximumCapacityPercent, let gauge = current?.gaugeCapacityPercent, abs(Double(macOS) - gauge) >= 1 {
                    Text("Maximum capacity is macOS's own rating, as System Settings shows it. It isn't worked out from these figures, so it can differ.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let cycles = current?.cycleCount ?? points.last?.cycles {
                DetailRow(label: "Cycle count", value: "\(cycles)")
            }
            let trend = HealthPoint.trend(points)
            if let first = trend.first, let last = trend.last, trend.count >= 2 {
                DetailRow(label: "Since \(first.day.formatted(.dateTime.day().month()))",
                          value: String(format: "%+.1f points", last.percent - first.percent))
                Sparkline(values: trend.map(\.percent)).frame(height: 18)
            } else {
                Text("A reading is kept each day; the trend appears as days pass.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Legend: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(label)
        }
    }
}

/// Charge level over time: a line, charging shaded green beneath it, time
/// on the adapter marked along the bottom, gaps (the Mac asleep) left empty.
struct ChargeChart: View {
    let points: [ChargePoint]
    let start: Date
    let end: Date

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let span = max(1, end.timeIntervalSince(start))
            let x = { (date: Date) in CGFloat(date.timeIntervalSince(start) / span) * size.width }
            let y = { (percent: Double) in size.height * (1 - CGFloat(percent / 100)) }
            // Longer than this between two points is a gap, not a line.
            let gap = max(180, span / 300 * 3)
            ZStack(alignment: .topLeading) {
                ForEach([0.0, 50, 100], id: \.self) { level in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y(level)))
                        path.addLine(to: CGPoint(x: size.width, y: y(level)))
                    }
                    .stroke(.quaternary, style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
                Path { path in
                    for (a, b) in zip(points, points.dropFirst()) where a.charging && b.date.timeIntervalSince(a.date) <= gap {
                        path.move(to: CGPoint(x: x(a.date), y: size.height))
                        path.addLine(to: CGPoint(x: x(a.date), y: y(a.percent)))
                        path.addLine(to: CGPoint(x: x(b.date), y: y(b.percent)))
                        path.addLine(to: CGPoint(x: x(b.date), y: size.height))
                        path.closeSubpath()
                    }
                }
                .fill(.green.opacity(0.35))
                Path { path in
                    for (a, b) in zip(points, points.dropFirst()) where a.onExternalPower && b.date.timeIntervalSince(a.date) <= gap {
                        path.addRect(CGRect(x: x(a.date), y: size.height - 3, width: max(1, x(b.date) - x(a.date)), height: 3))
                    }
                }
                .fill(.secondary.opacity(0.35))
                Path { path in
                    var drawing = false
                    for (index, point) in points.enumerated() {
                        let p = CGPoint(x: x(point.date), y: y(point.percent))
                        if drawing, index > 0, point.date.timeIntervalSince(points[index - 1].date) <= gap {
                            path.addLine(to: p)
                        } else {
                            path.move(to: p)
                            drawing = true
                        }
                    }
                }
                .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                Text("100%").font(.system(size: 9)).foregroundStyle(.tertiary).offset(x: 2, y: -1)
            }
        }
        .accessibilityLabel(points.last.map { "Battery charge history, now \(Int($0.percent)) percent" } ?? "Battery charge history")
    }
}

import Attribution
import BatteryTraceCore
import SwiftUI

/// Apps ranked by estimated energy over the chosen window.
struct AppsSection: View {
    @ObservedObject var model: AppModel
    @State private var expanded: Set<AppKey> = []
    @State private var showingExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Window", selection: $model.window) {
                    ForEach(HistoryWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Spacer()
                Button {
                    showingExplanation.toggle()
                } label: {
                    Label("Estimated", systemImage: "info.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("How per-app figures are estimated")
                .popover(isPresented: $showingExplanation, arrowEdge: .bottom) { EstimateExplanation() }
            }
            .padding(.horizontal, 14)

            if let summary = model.summary, !summary.apps.isEmpty || summary.totalJoules > 0 {
                list(summary)
                footer(summary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                Text(model.summary == nil ? "Measuring…" : "Nothing recorded in this window yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private func list(_ summary: WindowSummary) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(summary.apps.prefix(40)) { row in
                    AppRowView(
                        name: row.identity.name,
                        icon: AppIcons.shared.icon(for: row.identity),
                        joules: row.joules,
                        share: summary.share(of: row.joules),
                        processes: row.processes,
                        isExpanded: expanded.contains(row.id)
                    ) {
                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    }
                }
                AppRowView(
                    name: "System / Unattributed",
                    icon: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil) ?? NSImage(),
                    joules: summary.systemJoules,
                    share: summary.share(of: summary.systemJoules),
                    processes: [],
                    isExpanded: false,
                    caption: "Display, memory, Wi-Fi, SSD and what no counter covers",
                    toggle: {}
                )
            }
            .padding(.horizontal, 8)
        }
        .frame(maxHeight: 300)
    }

    private func footer(_ summary: WindowSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let basis: String = switch summary.basis {
            case .measured(.batteryTelemetry): "measured by the battery gauge"
            case .measured(.smc): "measured by the system power sensor"
            case .measured(.batteryDischarge): "measured from battery voltage × current"
            case .componentsOnly: "sum of measured components (no total available)"
            }
            Text("Total \(Units.energy(summary.totalJoules)) · average \(Units.watts(summary.averageWatts)), \(basis)")
            if summary.durationSeconds < model.window.seconds * 0.9 {
                Text("Recorded over the last \(Units.span(seconds: summary.durationSeconds)) so far.")
            }
            if summary.onBatterySeconds < summary.durationSeconds * 0.5 {
                Text("Mostly on the power adapter: this is power draw, not battery drain.")
            }
            if summary.scale < 0.98 {
                Text(String(format: "Components exceeded the measured total and were scaled by %.0f%%.", summary.scale * 100))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct AppRowView: View {
    let name: String
    let icon: NSImage
    let joules: Double
    let share: Double
    let processes: [ProcessShare]
    let isExpanded: Bool
    var caption: String?
    let toggle: () -> Void

    private var expandable: Bool { processes.count > 1 || processes.first?.name == ProcessShare.otherProcessesName }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: { if expandable { toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(expandable ? 1 : 0)
                        .frame(width: 8)
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).lineLimit(1).truncationMode(.middle)
                        if let caption {
                            Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        ShareBar(fraction: share)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Units.share(share)).monospacedDigit()
                        Text(Units.energy(joules)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)

            if isExpanded {
                ForEach(processes.prefix(12), id: \.name) { process in
                    HStack {
                        Text(process.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(process.pid == nil && process.name == ProcessShare.otherProcessesName ? .secondary : .primary)
                        Spacer()
                        Text(Units.energy(process.cpuJoules)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.leading, 46)
                    .padding(.trailing, 6)
                }
                Text("CPU by process; GPU and Neural Engine use is counted for the app as a whole.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 46)
                    .padding(.bottom, 4)
            }
        }
    }
}

struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.tint.opacity(0.7))
                .frame(width: max(2, proxy.size.width * min(1, fraction)))
        }
        .frame(height: 3)
    }
}

struct EstimateExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How these figures are made").font(.headline)
            Text("The total is measured: the battery gauge, or the Mac's power sensor. CPU, GPU and Neural Engine energy are measured by the chip.")
            Text("macOS has no per-app battery API, so each app's share is an estimate: the chip's measured energy is split in proportion to the kernel's own per-app energy counters. Helpers and background processes count for their app.")
            Text("Work done for an app by system services (drawing its windows, decoding its video) is counted for those services. Display, memory, Wi-Fi and the rest are in System / Unattributed.")
        }
        .font(.callout)
        .frame(width: 300)
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
    }
}

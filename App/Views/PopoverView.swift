import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    @State private var tab: Tab

    init(model: AppModel, openSettings: @escaping () -> Void, initialTab: Tab = .apps) {
        self.model = model
        self.openSettings = openSettings
        _tab = State(initialValue: initialTab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case apps = "Apps", system = "System", battery = "Battery"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummarySection(reading: model.reading, watts: model.smoothedWatts, series: model.totalSeries)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            switch tab {
            case .apps:
                AppsSection(model: model)
            case .system:
                SystemSection(report: model.report, series: model.componentSeries)
            case .battery:
                BatterySection(model: model)
            }

            Divider()
            HStack(spacing: 12) {
                Label("No root, no permissions", systemImage: "lock.shield")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Settings…", action: openSettings)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

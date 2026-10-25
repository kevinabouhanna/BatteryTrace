import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var launchAtLogin: LaunchAtLogin

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                loginStatus
            }

            Section("Menu bar") {
                Picker("Show", selection: $settings.menuBarStyle) {
                    ForEach(SettingsStore.MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Picker("While the window is closed", selection: $settings.closedInterval) {
                    ForEach(SettingsStore.closedIntervals, id: \.self) { Text("Every \(Int($0)) s").tag($0) }
                }
                Picker("While the window is open", selection: $settings.openInterval) {
                    ForEach(SettingsStore.openIntervals, id: \.self) { Text("Every \(Int($0)) s").tag($0) }
                }
            } header: {
                Text("Sampling")
            } footer: {
                Text("Apps are attributed once a minute while the window is closed, and at each reading while it's open. Sampling slows down in Low Power Mode and while the display sleeps, and stops while the Mac sleeps. Nothing is lost by sampling less often: every counter is cumulative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                Text("Battery Trace needs no permissions and no administrator password. It reads the battery gauge, the chip's energy counters and the kernel's per-app counters, all of which macOS makes available to any app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var loginStatus: some View {
        switch launchAtLogin.status {
        case .requiresApproval:
            HStack {
                Text("Waiting for your approval in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                    .controlSize(.small)
            }
        case .notFound where launchAtLogin.attempted:
            Text("macOS can't find this copy of Battery Trace to open at login. Move it to Applications and try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            if let error = launchAtLogin.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

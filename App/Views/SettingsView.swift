import AppKit
import ServiceManagement
import SwiftUI

// Settings' panes, each a grouped form in the shape of System Settings: labels
// on the left, controls on the right, a line of explanation under a section.
// `SettingsWindowController` puts them behind a toolbar.
//
// Quit is deliberately not here: in a menu bar app it lives on the status
// item's right-click menu, and in the app menu while Settings is open.

enum SettingsMetrics {
    /// Every pane's width, so switching panes only changes the height.
    static let paneWidth: CGFloat = 520
}

// MARK: - General

struct GeneralSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var launchAtLogin: LaunchAtLogin

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                loginStatus
            } footer: {
                SettingsFootnote("Opens Battery Trace when you log in. Off until you turn it on.")
            }

            Section {
                LabeledContent("Show") {
                    Picker("Show", selection: $settings.menuBarStyle) {
                        ForEach(SettingsStore.MenuBarStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Show icon", isOn: $settings.showsMenuBarIcon)
                    .toggleStyle(.switch)
            } header: {
                Text("Menu bar")
            } footer: {
                SettingsFootnote("Power is the whole Mac's, measured live. Without the icon, the reading alone stays in the menu bar. Right-click it, or click it with two fingers, for Settings and Quit.")
            }

            Section {
                LabeledContent("While the popover is closed") {
                    Picker("While the popover is closed", selection: $settings.closedInterval) {
                        ForEach(SettingsStore.closedIntervals, id: \.self) { Text("Every \(Int($0)) s").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("While the popover is open") {
                    Picker("While the popover is open", selection: $settings.openInterval) {
                        ForEach(SettingsStore.openIntervals, id: \.self) { Text("Every \(Int($0)) s").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Sampling")
            } footer: {
                SettingsFootnote("Apps are attributed once a minute while the popover is closed, and at every reading while it's open. Sampling slows in Low Power Mode and while the display sleeps, and stops while the Mac sleeps. Nothing is lost by sampling less often: every counter is cumulative.")
            }
        }
        .settingsForm()
    }

    @ViewBuilder
    private var loginStatus: some View {
        switch launchAtLogin.status {
        case .requiresApproval:
            LabeledContent {
                Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
            } label: {
                SettingsRowDetail("Waiting for your approval in System Settings › General › Login Items.")
            }
        case .notFound where launchAtLogin.attempted:
            SettingsRowDetail("macOS can't find this copy of Battery Trace to open at login. Move it to Applications and try again.")
        default:
            if let error = launchAtLogin.lastError { SettingsRowDetail(error) }
        }
    }
}

// MARK: - About

/// Which version this is, where to read more, what it reads, and where its
/// history lives.
struct AboutSettingsPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return "Version \(short)" + ((info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                    Text("Battery Trace").font(.system(size: 20, weight: .semibold))
                    Text(version).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Where your Mac's power goes: by app, and by part of the Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                link("How it works", "How power is attributed", "https://github.com/kevinabouhanna/BatteryTrace/blob/main/docs/ATTRIBUTION.md")
                link("What's new", "Release notes", "https://github.com/kevinabouhanna/BatteryTrace/releases/latest")
                link("Source code", "On GitHub", "https://github.com/kevinabouhanna/BatteryTrace")
            } footer: {
                SettingsFootnote("Free and open source, under the MIT licence.")
            }

            Section {
                LabeledContent("History") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryService.defaultURL])
                    }
                }
            } header: {
                Text("Privacy")
            } footer: {
                SettingsFootnote("No permissions, no administrator password, no network access, no telemetry. Battery Trace reads the battery gauge, the chip's energy counters and the kernel's per-app counters, which macOS makes available to any app. Its history stays in one file on this Mac; delete it to start over.")
            }
        }
        .settingsForm()
    }

    private func link(_ title: String, _ text: String, _ address: String) -> some View {
        LabeledContent(title) {
            Link(destination: URL(string: address)!) {
                Label(text, systemImage: "arrow.up.right.square").labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: - Shared

/// The line of explanation under a section, as System Settings sets it.
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A smaller line inside a row.
struct SettingsRowDetail: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// The grouped form every pane uses, at the shared width, as tall as its
    /// content so the window sizes itself to the pane.
    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: SettingsMetrics.paneWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

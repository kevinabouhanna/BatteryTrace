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
    @ObservedObject var alerts: PowerAlerts
    @ObservedObject var updates: UpdateChecker

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
                Toggle("Tell me when an app uses a lot of power", isOn: Binding(
                    get: { settings.notifiesHungryApps && alerts.permission != .denied },
                    set: { enabled in
                        guard enabled else {
                            settings.notifiesHungryApps = false
                            return
                        }
                        // macOS asks once, the first time; after that it remembers.
                        alerts.requestPermission { granted in settings.notifiesHungryApps = granted }
                    }
                ))
                .toggleStyle(.switch)
                if settings.notifiesHungryApps, alerts.permission != .denied {
                    LabeledContent("When an app averages more than") {
                        Picker("When an app averages more than", selection: $settings.alertThresholdWatts) {
                            ForEach(SettingsStore.alertThresholds, id: \.self) { Text("\(Int($0)) W").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if alerts.permission == .denied {
                    LabeledContent {
                        Button("Open Notifications") { alerts.openNotificationSettings() }
                    } label: {
                        SettingsRowDetail("Notifications are off for Battery Trace in System Settings.")
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                SettingsFootnote("For an app that keeps it up for 10 minutes, on battery only, and at most once an hour per app. macOS asks for permission the first time you turn this on.")
            }
            Section {
                LabeledContent {
                    HStack {
                        if case .available(let release) = updates.state {
                            Button("Download") { updates.download(release) }
                        }
                        Button("Check Now") { updates.check(interactive: true) }
                            .disabled(updates.state == .checking)
                    }
                } label: {
                    Text("Battery Trace \(updates.current.map(String.init(describing:)) ?? "development build")")
                    SettingsRowDetail(updateStatus)
                }
                Toggle("Check automatically once a day", isOn: $settings.checksForUpdates)
                    .toggleStyle(.switch)
            } header: {
                Text("Updates")
            } footer: {
                SettingsFootnote("One request to GitHub, which carries nothing about your Mac. Nothing installs by itself: Download opens the disk image.")
            }

        }
        .settingsForm()
    }

    private var updateStatus: String {
        switch updates.state {
        case .idle: "Not checked yet"
        case .checking: "Checking…"
        case .upToDate(let checked): "Up to date, checked \(checked.formatted(date: .omitted, time: .shortened))"
        case .available(let release): "Version \(release.version) is available"
        case .failed: "Couldn't check. Try again later."
        }
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

// MARK: - Measurement

/// How Battery Trace measures: who a service's work counts for, how often it
/// samples, and this Mac's display curve.
struct MeasurementSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var calibration: DisplayCalibrationController

    var body: some View {
        Form {
            Section {
                Toggle("Count work macOS services do for an app", isOn: $settings.countsBilledEnergy)
                    .toggleStyle(.switch)
            } header: {
                Text("Apps")
            } footer: {
                SettingsFootnote("When a service such as Spotlight's indexer works for an app, macOS records it. On, that work counts for the app; off, for the service that did it, as in Activity Monitor. Totals don't change.")
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

            if calibration.isAvailable {
                Section {
                    if let panel = calibration.panel {
                        LabeledContent("This Mac's display") {
                            Text(String(format: "%.1f-inch, up to %.0f nits", panel.diagonalInches, panel.peakNits))
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Backlight at full brightness") {
                        Text(fullBrightness).foregroundStyle(.secondary)
                    }
                    calibrationRow
                } header: {
                    Text("Display")
                } footer: {
                    SettingsFootnote("No sensor measures the display. Until it's calibrated, its power is estimated for this display from its size and peak brightness, with a curve measured on an M1 MacBook Air; other kinds of panel can differ. Calibrating measures this Mac's own: for under two minutes the display dims and brightens while the Mac stays idle, then your brightness is put back.")
                }
            }

        }
        .settingsForm()
    }

    private var fullBrightness: String {
        if let measured = settings.displayCalibration, measured.isTrustworthy {
            return String(format: "%.1f W, measured on this Mac %@", measured.curve.watts(slider: 1),
                          measured.date.formatted(date: .abbreviated, time: .omitted))
        }
        guard let panel = calibration.panel else { return "Estimated" }
        return String(format: "About %.1f W, estimated", panel.estimatedFullBrightnessWatts)
    }

    @ViewBuilder
    private var calibrationRow: some View {
        switch calibration.state {
        case .running(let step, let steps):
            LabeledContent {
                Button("Cancel") { calibration.cancel() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calibrating… keep the Mac idle")
                    ProgressView(value: Double(step), total: Double(steps)).frame(width: 220)
                }
            }
        default:
            LabeledContent {
                HStack {
                    if settings.displayCalibration != nil {
                        Button("Reset") { calibration.reset() }
                    }
                    Button("Calibrate…") { calibration.start() }
                }
            } label: {
                switch calibration.state {
                case .finished(let result):
                    SettingsRowDetail(String(format: "Done: about %.1f W at full brightness.", result.curve.watts(slider: 1)))
                case .tooNoisy:
                    SettingsRowDetail("Something else was busy, so the measurement was too noisy to use. Quit busy apps and try again.")
                case .failed:
                    SettingsRowDetail("Calibration couldn't finish. Nothing was changed.")
                default:
                    Text("Measure this Mac's display")
                }
            }
        }
    }

}

// MARK: - History

/// What Battery Trace keeps, how big it is, and getting it out.
struct HistorySettingsPane: View {
    var onExport: () -> Void = {}
    @State private var fileSize: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Totals and parts of the Mac", value: "Minute by minute, 7 days")
                LabeledContent("Apps", value: "Minute by minute for 24 hours, then hourly for 7 days")
                LabeledContent("Battery health", value: "One reading a day, all of them")
                LabeledContent("Size on disk", value: fileSize ?? "—")
            } header: {
                Text("Kept on this Mac")
            } footer: {
                SettingsFootnote("Readings older than that are removed every hour, and the file is capped at 64 MB. Nothing leaves this Mac.")
            }

            Section {
                LabeledContent("Export as CSV") {
                    Button("Export…", action: onExport)
                }
                LabeledContent("History file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryService.defaultURL])
                    }
                }
            } footer: {
                SettingsFootnote("Export writes two spreadsheet-ready files: energy by app, and the Mac's totals and parts, minute by minute. To start over, quit Battery Trace and delete the history file.")
            }
        }
        .settingsForm()
        .onAppear { fileSize = Self.sizeOnDisk() }
    }

    /// The database with its write-ahead log, as Finder would count it.
    static func sizeOnDisk() -> String? {
        let base = HistoryService.defaultURL.path
        let bytes = ["", "-wal", "-shm"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: base + $0))?[.size] as? Int64
        }
        guard !bytes.isEmpty else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes.reduce(0, +), countStyle: .file)
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
                Text("No telemetry. Battery Trace reads the battery gauge, the chip's energy counters and the kernel's per-app counters, which macOS makes available to any app. Its history stays on this Mac. It goes online only to ask GitHub for the newest version: when you check, or once a day if you turn that on.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
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
            // Up to the pane's width, not exactly it: the scroll view around
            // the pane fixes the width, and a scroll bar shown always takes
            // its width from inside it.
            .frame(maxWidth: SettingsMetrics.paneWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

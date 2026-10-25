import Combine
import Foundation
import Sampling
import ServiceManagement

/// The user's choices, kept in UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case watts, batteryPercent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .watts: "Power (watts)"
            case .batteryPercent: "Battery percentage"
            }
        }
    }

    /// Live readings while the popover is closed.
    static let closedIntervals: [Double] = [2, 5, 10, 30]
    /// While the popover is open.
    static let openIntervals: [Double] = [1, 2]

    private let defaults: UserDefaults

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    /// The ⚡︎ (or battery) symbol before the reading. The reading itself
    /// always shows, so the item can still be clicked.
    @Published var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: "showsMenuBarIcon") }
    }
    @Published var closedInterval: Double {
        didSet { defaults.set(closedInterval, forKey: "closedInterval") }
    }
    @Published var openInterval: Double {
        didSet { defaults.set(openInterval, forKey: "openInterval") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarStyle = defaults.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:)) ?? .watts
        showsMenuBarIcon = defaults.object(forKey: "showsMenuBarIcon") == nil ? true : defaults.bool(forKey: "showsMenuBarIcon")
        let closed = defaults.double(forKey: "closedInterval")
        closedInterval = Self.closedIntervals.contains(closed) ? closed : 5
        let open = defaults.double(forKey: "openInterval")
        openInterval = Self.openIntervals.contains(open) ? open : 2
    }

    var policy: SamplingPolicy { SamplingPolicy(closedInterval: closedInterval, openInterval: openInterval) }
}

/// Launch at login, through `SMAppService.mainApp`. Off by default: Battery
/// Trace never registers itself. The state shown is always read back from
/// the system, so it stays right if the user changes it in System Settings.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var lastError: String?
    /// Whether the user has tried to turn it on this session: macOS reports
    /// `.notFound` for an app that was never registered, which is only worth
    /// explaining once they ask.
    @Published private(set) var attempted = false

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        attempted = true
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

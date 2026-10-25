import AppKit
import Attribution
import BatteryTraceCore
@preconcurrency import UserNotifications

/// Notifications for apps that keep using a lot of power on battery.
///
/// Off by default; macOS asks for permission only when it's turned on. Fed
/// every attribution (once a minute with the popover closed), so it samples
/// nothing of its own.
@MainActor
final class PowerAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum Permission { case unknown, allowed, denied }

    @Published private(set) var permission: Permission = .unknown
    /// Opens the popover; set by `AppDelegate`.
    var onOpen: () -> Void = {}

    private let settings: SettingsStore
    private var detector: PowerHungryDetector

    init(settings: SettingsStore) {
        self.settings = settings
        detector = PowerHungryDetector(thresholdWatts: settings.alertThresholdWatts)
        super.init()
        UNUserNotificationCenter.current().delegate = self
        refreshPermission()
    }

    func receive(_ report: IntervalReport) {
        guard settings.notifiesHungryApps, permission != .denied else { return }
        detector.thresholdWatts = settings.alertThresholdWatts
        for alert in detector.add(report) { post(alert, battery: report.system.battery) }
    }

    /// Asks macOS once; `completion(true)` if notifications may be shown.
    func requestPermission(completion: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.permission = granted ? .allowed : .denied
                    completion(granted)
                }
            }
        }
    }

    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch status {
                    case .authorized, .provisional: self.permission = .allowed
                    case .denied: self.permission = .denied
                    default: self.permission = .unknown
                    }
                }
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Development aid: `-testNotification YES` asks for permission, posts a
    /// sample, prints how many notifications macOS has delivered, and quits.
    func runDeliveryTest() {
        UNUserNotificationCenter.current().getNotificationSettings { current in
            print("notification test: status before asking = \(current.authorizationStatus.rawValue) (0 not asked, 1 denied, 2 allowed)")
        }
        requestPermission { granted in
            guard granted else { print("notification test: permission not granted"); NSApp.terminate(nil); return }
            let sample = PowerHungryDetector.Alert(
                identity: AppIdentity(key: .command("test"), name: "Battery Trace (test)", kind: .app), averageWatts: 2.4, seconds: 600)
            var battery = BatterySnapshot()
            battery.nominalCapacityMAh = 3360
            battery.voltageV = 12.0
            self.post(sample, battery: battery)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                    print("notification test: \(delivered.count) delivered; titles: \(delivered.map(\.request.content.title))")
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }
    }

    private func post(_ alert: PowerHungryDetector.Alert, battery: BatterySnapshot) {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.identity.name) is using a lot of power"
        var body = "About \(Units.watts(alert.averageWatts)) for the last \(Int((alert.seconds / 60).rounded())) minutes, on battery."
        if let share = Self.batteryShare(watts: alert.averageWatts, battery: battery) {
            body += " Roughly \(share)% of your battery an hour."
        }
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: "hungry-\(alert.identity.key.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Watts as a share of a full battery an hour, from its rated capacity.
    static func batteryShare(watts: Double, battery: BatterySnapshot) -> Int? {
        guard let mAh = battery.nominalCapacityMAh, let volts = battery.voltageV, mAh > 0, volts > 0 else { return nil }
        let wattHours = Double(mAh) / 1000 * volts
        return Int((watts / wattHours * 100).rounded())
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onOpen() } }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

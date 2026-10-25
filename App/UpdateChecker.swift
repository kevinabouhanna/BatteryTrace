import AppKit
import Updates

/// Check for Updates…, and the optional once-a-day check.
///
/// Nothing here goes online by itself unless the user turned the daily check
/// on in Settings › About. An update is never installed: Download opens the
/// disk image in the browser, as the first download did.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(checked: Date)
        case available(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// A newer release found by any check, until this version is replaced.
    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    let current: AppVersion?
    private let settings: SettingsStore
    private let defaults: UserDefaults
    private var timer: Timer?
    private static let lastCheckKey = "lastUpdateCheck"
    private static let day: TimeInterval = 24 * 60 * 60

    init(settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    /// Starts or stops the daily check to match the setting. Checks now if
    /// the last one was over a day ago.
    func applySetting() {
        timer?.invalidate()
        timer = nil
        guard settings.checksForUpdates else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        if last.map({ Date().timeIntervalSince($0) >= Self.day }) ?? true {
            check(interactive: false)
        }
        // Hourly with an hour's tolerance; a check runs only once a day is up.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.checksForUpdates else { return }
                let last = self.defaults.object(forKey: Self.lastCheckKey) as? Date
                if last.map({ Date().timeIntervalSince($0) >= Self.day }) ?? true { self.check(interactive: false) }
            }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asks GitHub. `interactive` shows the answer in an alert, whatever it
    /// is; otherwise only Settings and the right-click menu show it.
    func check(interactive: Bool) {
        guard state != .checking else { return }
        guard let current else {
            if interactive { show(.failed("This is a development build, without a version to compare.")) }
            return
        }
        state = .checking
        Task {
            let outcome = await UpdateCheck.check(current: current)
            defaults.set(Date(), forKey: Self.lastCheckKey)
            switch outcome {
            case .upToDate: state = .upToDate(checked: Date())
            case .available(let release): state = .available(release)
            case .failed(let reason): state = .failed(reason)
            }
            if interactive { show(state) }
        }
    }

    /// The alert for an update that is already known, from the menu.
    func showAvailable() {
        if let available { show(.available(available)) }
    }

    func download(_ release: Release) {
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    private func show(_ state: State) {
        let alert = NSAlert()
        switch state {
        case .available(let release):
            alert.messageText = "Battery Trace \(release.version) is available"
            var text = "You have \(current.map(String.init(describing:)) ?? "a development build"). "
                + "Download opens the disk image; drag Battery Trace into Applications again and choose Replace. Your settings and history stay."
            if !release.whatsNew.isEmpty { text += "\n\nWhat's new:\n" + Self.shortened(release.whatsNew) }
            alert.informativeText = text
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: download(release)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
            default: break
            }
            return
        case .upToDate:
            alert.messageText = "Battery Trace is up to date"
            alert.informativeText = "\(current.map(String.init(describing:)) ?? "This") is the newest version."
        case .failed(let reason):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = reason
        case .idle, .checking:
            return
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Release notes can run long; an alert should not.
    static func shortened(_ text: String, limit: Int = 700) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: "\n") ?? cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "\n…"
    }
}

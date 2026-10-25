import AppKit

/// A menu bar app: no Dock icon (`LSUIElement`), no main window. AppKit's
/// lifecycle rather than SwiftUI's `App`, so nothing is created that the
/// status item and popover don't need.
@main
enum BatteryTraceApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var statusItem: StatusItemController!
    private var conditions: SystemConditions?
    private var terminationSignal: DispatchSourceSignal?
    private let launchAtLogin = LaunchAtLogin()
    private var alerts: PowerAlerts!
    /// Built when Settings opens and released when it closes, so a closed
    /// Settings holds no view hierarchy.
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel(settings: SettingsStore())
        statusItem = StatusItemController(model: model)
        statusItem.openSettings = { [weak self] in self?.showSettings() }
        statusItem.openAbout = { [weak self] in self?.showAbout() }
        statusItem.exportHistory = { [weak self] in self?.exportHistory() }
        statusItem.openSettingsWindow = { [weak self] in self?.openSettingsWindow }
        conditions = SystemConditions(engine: model.engine, history: model.history)
        alerts = PowerAlerts(settings: model.settings)
        alerts.onOpen = { [weak self] in self?.statusItem.showPopover() }
        model.onReport = { [weak self] report in self?.alerts.receive(report) }
        model.start()

        // `kill` (and logout scripts) send SIGTERM, which skips
        // applicationWillTerminate: write buffered history first.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.activate()
        terminationSignal = source

        // Development aids: `-openPopover YES`, `-openSettings YES`, `-snapshotTo <dir>`.
        if UserDefaults.standard.bool(forKey: "openPopover") { statusItem.showPopover() }
        if UserDefaults.standard.bool(forKey: "openSettings") { showSettings() }
        if UserDefaults.standard.bool(forKey: "testNotification") { alerts.runDeliveryTest() }
        if let directory = UserDefaults.standard.string(forKey: "snapshotTo") { DebugSnapshot.run(model: model, to: directory) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.history.flushNow()
    }

    // MARK: Export

    /// Asks for a folder, writes the history there as two CSV files, and
    /// shows them in Finder.
    @objc func exportHistory() {
        statusItem.closePopover()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for two CSV files: energy by app, and the Mac's totals and parts, minute by minute."
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        model.history.exportCSV(to: directory) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let files):
                    NSWorkspace.shared.activateFileViewerSelecting(files)
                case .failure(let error):
                    let alert = NSAlert(error: error)
                    alert.messageText = "Battery Trace couldn't export its history"
                    alert.runModal()
                }
            }
        }
    }

    // MARK: Settings window

    private var openSettingsWindow: NSWindow? {
        guard let window = settingsController?.window, window.isVisible else { return nil }
        return window
    }

    @objc func showSettings() {
        show(pane: nil)
    }

    @objc func showAbout() {
        show(pane: .about)
    }

    private func show(pane: SettingsPane?) {
        statusItem.closePopover()
        let settings = settingsController ?? makeSettings()
        let wasVisible = settings.isVisible
        launchAtLogin.refresh()
        settings.select(pane)
        settings.fitSelectedPane()
        // Not re-centred if it's already up: it may have been moved.
        present(settings, reposition: !wasVisible)
        // Opens with nothing focused, for the reason the popover does.
        if !wasVisible {
            DispatchQueue.main.async { settings.window.makeFirstResponder(nil) }
        }
    }

    private func makeSettings() -> SettingsWindowController {
        let settings = SettingsWindowController(settings: model.settings, launchAtLogin: launchAtLogin, alerts: alerts,
                                                onExport: { [weak self] in self?.exportHistory() })
        settings.window.delegate = self
        settings.highestTop = { [weak self] screen in
            screen.frame.maxY - (self?.statusItem.menuBarHeight(on: screen) ?? 0)
        }
        settingsController = settings
        return settings
    }

    /// An ordinary app while Settings is open (in the Dock and the app
    /// switcher, with a menu bar of its own), and an accessory app again once
    /// it closes; see `windowWillClose`.
    ///
    /// As an accessory app it had none of those, and with an auto-hidden menu
    /// bar that lost the window outright: revealing the bar activates an app
    /// that owns one, and Settings went behind it with nothing to bring it
    /// back. NetworkMonitor measured this on macOS 27.
    private func present(_ settings: SettingsWindowController, reposition: Bool) {
        NSApp.mainMenu = mainMenu
        NSApp.setActivationPolicy(.regular)
        if reposition { settings.position() }
        NSApp.activate(ignoringOtherApps: true)
        settings.window.makeKeyAndOrderFront(nil)
    }

    /// Back to a menu bar app when Settings closes. macOS hands focus back to
    /// the app that had it before.
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsController?.window else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = nil
        DispatchQueue.main.async { [weak self] in self?.settingsController = nil }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Login Items or notifications may have been changed in System Settings meanwhile.
        launchAtLogin.refresh()
        alerts.refreshPermission()
    }

    /// Opening Battery Trace again while it runs, or clicking its Dock icon
    /// (there only while Settings is open), shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// The menu bar Battery Trace shows while Settings is open, and only then.
    /// A regular app owns the menu bar, so it needs one; it is also what gives
    /// the window ⌘W.
    private lazy var mainMenu: NSMenu = {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Battery Trace", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Battery Trace", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Battery Trace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let menuBar = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            menuBar.addItem(item)
        }
        return menuBar
    }()
}

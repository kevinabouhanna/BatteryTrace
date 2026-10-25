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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var conditions: SystemConditions?
    private var terminationSignal: DispatchSourceSignal?
    private lazy var settingsWindow = SettingsWindowController(settings: model!.settings, launchAtLogin: LaunchAtLogin())

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel(settings: SettingsStore())
        self.model = model
        statusItem = StatusItemController(model: model, openSettings: { [weak self] in self?.settingsWindow.show() })
        conditions = SystemConditions(engine: model.engine, history: model.history)
        model.start()

        // `kill` (and logout scripts) send SIGTERM, which skips
        // applicationWillTerminate: write buffered history first.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.activate()
        terminationSignal = source

        // Development aid: `open "Battery Trace.app" --args -openPopover YES`.
        if UserDefaults.standard.bool(forKey: "openPopover") { statusItem?.showPopover() }
        if let directory = UserDefaults.standard.string(forKey: "snapshotTo") { DebugSnapshot.run(model: model, to: directory) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.history.flushNow()
    }
}

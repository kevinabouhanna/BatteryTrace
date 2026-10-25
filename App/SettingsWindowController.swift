import AppKit
import SwiftUI

/// A plain window for Settings. A menu bar app has to bring itself forward
/// for the window to appear above others.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let launchAtLogin: LaunchAtLogin
    private var window: NSWindow?

    init(settings: SettingsStore, launchAtLogin: LaunchAtLogin) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
    }

    func show() {
        launchAtLogin.refresh()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, launchAtLogin: launchAtLogin)))
            window.title = "Battery Trace Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The user may have changed Login Items in System Settings meanwhile.
        launchAtLogin.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // Free the view hierarchy; it's rebuilt the next time.
        window?.contentViewController = nil
        window = nil
    }
}

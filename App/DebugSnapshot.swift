import AppKit
import SwiftUI

/// Development aid: renders the popover offscreen to PNGs, then quits.
/// `open "Battery Trace.app" --args -snapshotTo /some/dir`
@MainActor
enum DebugSnapshot {
    static func run(model: AppModel, to directory: String) {
        model.popoverWillShow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            for tab in PopoverView.Tab.allCases {
                let view = NSHostingView(rootView: PopoverView(model: model, openSettings: {}, initialTab: tab))
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("popover-\(tab.rawValue).png"))
                }
            }
            let launchAtLogin = LaunchAtLogin()
            let panes: [(String, AnyView)] = [
                ("settings-general", AnyView(GeneralSettingsPane(settings: model.settings, launchAtLogin: launchAtLogin, alerts: PowerAlerts(settings: model.settings),
                                                                calibration: DisplayCalibrationController(settings: model.settings)))),
                ("settings-about", AnyView(AboutSettingsPane())),
            ]
            for (name, pane) in panes {
                let view = NSHostingView(rootView: pane.background(Color(nsColor: .windowBackgroundColor)))
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }
}


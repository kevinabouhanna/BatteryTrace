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
            let settings = NSHostingView(rootView: SettingsView(settings: model.settings, launchAtLogin: LaunchAtLogin()))
            settings.frame = NSRect(origin: .zero, size: settings.fittingSize)
            let window = NSWindow(contentRect: settings.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = settings
            settings.layoutSubtreeIfNeeded()
            if let rep = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) {
                settings.cacheDisplay(in: settings.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
            }
            NSApp.terminate(nil)
        }
    }
}

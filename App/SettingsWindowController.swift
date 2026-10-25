import AppKit
import SwiftUI

/// One area of Settings, a button in the window's toolbar.
enum SettingsPane: String, CaseIterable {
    case general, about

    var title: String {
        switch self {
        case .general: "General"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }

    private static let lastKey = "settingsPane"

    /// The pane Settings last showed, which it reopens on.
    static var last: SettingsPane {
        SettingsPane(rawValue: UserDefaults.standard.string(forKey: lastKey) ?? "") ?? .general
    }

    func remember() { UserDefaults.standard.set(rawValue, forKey: Self.lastKey) }
}

/// The Settings window, in the shape NetworkMonitor's takes: a toolbar of
/// panes that always shows which one is open, the window titled after the pane
/// and sized to it, minimise and zoom dimmed, the last pane remembered.
///
/// `AppDelegate` owns its lifecycle: activation policy, menu bar, position.
@MainActor
final class SettingsWindowController: NSObject {
    let window: NSWindow
    private let tabs = PaneTabViewController()
    private var sizeObservation: NSKeyValueObservation?

    /// How high the window's top may go on a screen: just under the menu bar,
    /// whose real height `AppDelegate` knows. An auto-hidden menu bar leaves
    /// `visibleFrame` running to the top of the screen and covers the title
    /// bar whenever it's revealed.
    var highestTop: (NSScreen) -> CGFloat = { $0.visibleFrame.maxY }

    init(settings: SettingsStore, launchAtLogin: LaunchAtLogin, alerts: PowerAlerts, onExport: @escaping () -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.paneWidth, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        tabs.tabStyle = .toolbar
        // At once, no crossfade: NetworkMonitor measured 0.7 s of lag from it.
        tabs.transitionOptions = [.allowUserInteraction]
        for pane in SettingsPane.allCases {
            let host: NSHostingController<AnyView>
            switch pane {
            case .general: host = NSHostingController(rootView: AnyView(GeneralSettingsPane(settings: settings, launchAtLogin: launchAtLogin, alerts: alerts, onExport: onExport)))
            case .about: host = NSHostingController(rootView: AnyView(AboutSettingsPane()))
            }
            host.sizingOptions = [.preferredContentSize]
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        // Only now: loading the tabs selects the first pane by itself, which
        // isn't a choice to remember.
        tabs.onSelect = { [weak self] pane in self?.didSelect(pane) }
        window.toolbarStyle = .preference
        window.toolbar?.allowsUserCustomization = false
        window.isReleasedWhenClosed = false
    }

    var isVisible: Bool { window.isVisible }

    /// Selects `pane`, or the last one viewed.
    func select(_ pane: SettingsPane?) {
        let target = pane ?? .last
        if let index = SettingsPane.allCases.firstIndex(of: target), tabs.selectedTabViewItemIndex != index {
            tabs.selectedTabViewItemIndex = index
        } else {
            didSelect(target)
        }
    }

    /// Sizes the window to the selected pane now, so it can be positioned at
    /// its real size before it's shown.
    func fitSelectedPane() {
        guard let child = tabs.tabView.selectedTabViewItem?.viewController else { return }
        child.view.layoutSubtreeIfNeeded()
        fit(child.preferredContentSize.height > 0 ? child.preferredContentSize : child.view.fittingSize)
    }

    private func didSelect(_ pane: SettingsPane) {
        pane.remember()
        window.title = pane.title
        guard let child = tabs.tabViewItems.first(where: { $0.identifier as? String == pane.rawValue })?.viewController else { return }
        // Follows the pane's size as its content changes, not only on selection.
        sizeObservation = child.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] child, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit(child.preferredContentSize) } }
        }
    }

    /// Resizes to a pane of `size`, at once, keeping the window's top edge
    /// and horizontal centre, within the screen below the menu bar.
    private func fit(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let wanted = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var frame = NSRect(x: window.frame.midX - wanted.width / 2, y: window.frame.maxY - wanted.height,
                           width: wanted.width, height: wanted.height)
        if let screen = window.screen ?? NSScreen.main {
            let top = min(screen.visibleFrame.maxY, highestTop(screen))
            frame.origin.y = min(max(frame.origin.y, screen.visibleFrame.minY), top - frame.height)
        }
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// Centres the window on its screen, its title bar clear of the menu bar
    /// even when that bar is auto-hidden and drawn over windows.
    func position() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        frame.origin.x = screen.frame.midX - frame.width / 2
        let centredTop = screen.frame.midY + frame.height / 2
        frame.origin.y = min(centredTop, highestTop(screen)) - frame.height
        frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
        window.setFrame(frame, display: false)
    }
}

/// Reports which pane was chosen. `NSTabViewController` is already the tab
/// view's delegate, so the hook is an override.
private final class PaneTabViewController: NSTabViewController {
    var onSelect: ((SettingsPane) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: id) { onSelect?(pane) }
    }
}

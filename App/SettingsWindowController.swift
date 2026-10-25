import AppKit
import SwiftUI

/// One area of Settings, a button in the window's toolbar.
enum SettingsPane: String, CaseIterable {
    case general, measurement, history, about

    var title: String {
        switch self {
        case .general: "General"
        case .measurement: "Measurement"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .measurement: "gauge.with.dots.needle.50percent"
        case .history: "clock.arrow.circlepath"
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

/// The Settings window, in the shape NetworkMonitor's takes:
///
/// - a toolbar of panes that always shows which one is open;
/// - the window titled after the pane, and sized to it, up to the height of
///   the screen below the menu bar, past which the pane scrolls;
/// - minimise and zoom dimmed, the last pane remembered.
///
/// `AppDelegate` owns its lifecycle: activation policy, menu bar, position.
@MainActor
final class SettingsWindowController: NSObject {
    let window: NSWindow
    private let tabs = PaneTabViewController()
    private var sizeObservation: NSKeyValueObservation?
    /// Caps the content at the screen's height; see `keepOnScreen()`.
    private var heightCap: NSLayoutConstraint!
    private var observers: [NSObjectProtocol] = []
    /// The frame at the last resize or move; see `windowDidResize()`.
    private var lastFrame: NSRect?

    /// How high the window's top may go on a screen: just under the menu bar,
    /// whose real height `AppDelegate` knows. An auto-hidden menu bar leaves
    /// `visibleFrame` running to the top of the screen and covers the title
    /// bar whenever it's revealed.
    var highestTop: (NSScreen) -> CGFloat = { $0.visibleFrame.maxY }

    init(settings: SettingsStore, launchAtLogin: LaunchAtLogin, alerts: PowerAlerts, calibration: DisplayCalibrationController,
         updates: UpdateChecker, onExport: @escaping () -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.paneWidth, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        tabs.tabStyle = .toolbar
        // At once, no crossfade: NetworkMonitor measured 0.7 s of lag from it.
        tabs.transitionOptions = [.allowUserInteraction]
        for pane in SettingsPane.allCases {
            let host: NSViewController
            switch pane {
            case .general: host = Self.paneHost(GeneralSettingsPane(settings: settings, launchAtLogin: launchAtLogin, alerts: alerts, updates: updates))
            case .measurement: host = Self.paneHost(MeasurementSettingsPane(settings: settings, calibration: calibration))
            case .history: host = Self.paneHost(HistorySettingsPane(onExport: onExport))
            case .about: host = Self.paneHost(AboutSettingsPane())
            }
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

        // Required, so it outranks every pane's own height: a pane taller
        // than this scrolls inside the window instead of stretching it.
        heightCap = tabs.view.heightAnchor.constraint(lessThanOrEqualToConstant: 10_000)
        heightCap.isActive = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidResize() }
            },
            // Dragged by the user: that is where it stays centred from now on.
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lastFrame = self?.window.frame }
            },
            // Moved to a smaller screen, it has to fit that one.
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepOnScreen() }
            },
        ]
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isVisible: Bool { window.isVisible }

    /// A pane in a scroll view that scrolls only once the pane is taller than
    /// the window can be. The scroll view takes the pane's full height as its
    /// own, so up to then the window grows and shrinks with the pane.
    static func paneHost<Content: View>(_ view: Content) -> NSViewController {
        let host = PaneHostingController(view, width: SettingsMetrics.paneWidth)
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    /// Whether a pane scrolls: taller than the window can be on this screen.
    static func scrolls(paneHeight: CGFloat, tallest: CGFloat) -> Bool {
        paneHeight > tallest + 0.5
    }

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
        keepOnScreen()
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

    /// Resizes to a pane of `size`, at once. See `frame(for:current:usable:)`.
    private func fit(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        keepOnScreen()
        let wanted = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let frame = Self.frame(for: wanted, current: window.frame, usable: usableFrame())
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// The part of the window's screen below the menu bar. Before the window
    /// is first shown it has no screen; it opens on the main one.
    private func usableFrame() -> NSRect? {
        (window.screen ?? NSScreen.main).map { screen in
            var usable = screen.visibleFrame
            usable.size.height = min(usable.maxY, highestTop(screen)) - usable.minY
            return usable
        }
    }

    private func windowDidResize() {
        if let lastFrame {
            let centred = Self.centred(window.frame, after: lastFrame)
            if centred != window.frame { window.setFrame(centred, display: true) }
        }
        lastFrame = window.frame
        keepOnScreen()
    }

    /// Keeps the window within its screen. A pane's height can change without
    /// `fit(_:)` (a calibration finishing, a notice appearing), and Auto Layout
    /// then resizes the window keeping its top edge, which can run it off the
    /// bottom of the screen. So the content is capped at the screen's height,
    /// the pane scrolls past it, and a window that grew past the bottom moves up.
    private func keepOnScreen() {
        guard let usable = usableFrame() else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let cap = usable.height - chrome
        if heightCap.constant != cap { heightCap.constant = cap }
        if let pane = tabs.tabView.selectedTabViewItem?.viewController,
           let scrolling = (pane as? ScrollingPane)?.scrolling {
            let scrolls = Self.scrolls(paneHeight: pane.preferredContentSize.height, tallest: cap)
            if scrolling.scrolls != scrolls { scrolling.scrolls = scrolls }
        }
        let frame = Self.frame(for: window.frame.size, current: window.frame, usable: usable)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// Where the window goes for a pane that wants a frame of `size`: centred
    /// where it is, top edge kept, within `usable`. Never off the bottom of
    /// the screen, never above the menu bar, and never taller than the space
    /// between them: past that, the pane scrolls.
    static func frame(for size: NSSize, current: NSRect, usable: NSRect?) -> NSRect {
        var frame = NSRect(x: current.midX - size.width / 2, y: current.maxY - size.height,
                           width: size.width, height: size.height)
        guard let usable else { return frame }
        if frame.height > usable.height {
            frame.size.height = usable.height
            frame.origin.y = current.maxY - frame.height
        }
        frame.origin.y = min(max(frame.origin.y, usable.minY), usable.maxY - frame.height)
        return frame
    }

    /// `frame` moved back to the centre of `last`, when Auto Layout resized it
    /// keeping the left edge rather than the centre (NetworkMonitor #57).
    static func centred(_ frame: NSRect, after last: NSRect) -> NSRect {
        guard frame.width != last.width, frame.minX == last.minX else { return frame }
        var centred = frame
        centred.origin.x = last.midX - frame.width / 2
        return centred
    }

    /// For `-settingsReport`: how the window fitted the pane on screen.
    var layoutReport: String {
        let pane = tabs.tabView.selectedTabViewItem?.viewController
        let scrolls = (pane as? ScrollingPane)?.scrolling.scrolls ?? false
        let usable = usableFrame()?.height ?? 0
        return String(format: "%@: pane %.0f pt, window %.0f pt (content %.0f, cap %.0f), usable screen %.0f pt, on screen %@, scrolls %@",
                      window.title, pane?.preferredContentSize.height ?? 0, window.frame.height, window.contentLayoutRect.height,
                      heightCap.constant, usable, usableFrame().map { $0.contains(window.frame) } == true ? "yes" : "NO",
                      scrolls ? "yes" : "no")
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
        lastFrame = window.frame
    }
}

/// Whether the pane on screen scrolls, which is when it shows a scroll bar.
/// Kept out of panes that fit, so a scroll bar shown always can't take width
/// from them and rewrap a footnote.
final class PaneScrolling: ObservableObject {
    @Published var scrolls = false
}

@MainActor
protocol ScrollingPane: AnyObject {
    var scrolling: PaneScrolling { get }
}

/// A pane in its scroll view, at the width every pane shares.
struct PaneScrollView<Content: View>: View {
    @ObservedObject var scrolling: PaneScrolling
    let width: CGFloat
    let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(scrolling.scrolls ? .automatic : .never)
        .frame(width: width)
    }
}

private final class PaneHostingController<Content: View>: NSHostingController<PaneScrollView<Content>>, ScrollingPane {
    let scrolling: PaneScrolling

    init(_ content: Content, width: CGFloat) {
        let scrolling = PaneScrolling()
        self.scrolling = scrolling
        super.init(rootView: PaneScrollView(scrolling: scrolling, width: width, content: content))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }
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

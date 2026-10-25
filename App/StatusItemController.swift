import AppKit
import BatteryTraceCore
import SwiftUI

/// The menu bar item and its popover.
///
/// Follows NetworkMonitor's popover behaviour, measured there on macOS 27:
/// semi-transient, so losing focus alone never closes it; an outside-click
/// monitor closes it on clicks elsewhere; an auto-hidden menu bar appearing
/// is ridden out rather than taken for a switch to another app; and it
/// anchors to a stand-in window so it doesn't jump when the menu bar hides.
///
/// The button's title is set only when its text changes. The popover's
/// SwiftUI content is created when it opens and released when it closes, so a
/// closed popover holds no view hierarchy and does no layout.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    /// Opens Settings, or its About pane. Set by `AppDelegate`.
    var openSettings: () -> Void = {}
    var openAbout: () -> Void = {}
    var exportHistory: () -> Void = {}
    var updates: UpdateChecker?
    /// The Settings window while it's open, which the popover leaves where it is.
    var openSettingsWindow: () -> NSWindow? = { nil }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var shownText = ""
    /// The symbol on show, nil when hidden; reset to redraw.
    private var shownSymbol: String??

    private var outsideClickMonitor: Any?
    /// Pointer watchers that exist only while a revealed menu bar holds the
    /// focus the popover had. See `restoreFocusWhenMenuBarHides()`.
    private var menuBarMonitors: [Any] = []
    /// Invisible stand-in for the status item that the popover anchors to.
    private var anchorWindow: NSWindow?
    /// The app the popover opened over while Settings was open behind it, to
    /// hand focus back to when the popover is dismissed.
    private var appUnderPopover: NSRunningApplication?
    /// Set while the app activates for the popover, so `appDidBecomeActive`
    /// can tell that apart from ⌘-Tab or the Dock.
    private var activatingForPopover = false
    /// Set while `closePopover` closes it, so `popoverShouldClose` can tell
    /// that apart from Esc.
    private var closingPopover = false

    init(model: AppModel) {
        self.model = model
        super.init()
        // Semi-transient, not transient: an auto-hidden menu bar takes focus
        // just by appearing, so `appDidResignActive` decides instead.
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Right-clicks too (a two-finger click on a trackpad is one), for the menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("Battery Trace")
        }
        model.onMenuBarChange = { [weak self] in self?.updateButton() }
        updateButton()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: Button

    private func updateButton() {
        guard let button = item.button else { return }
        let settings = model.settings
        let symbol: String? = settings.showsMenuBarIcon ? (settings.menuBarStyle == .watts ? "bolt.fill" : "battery.75percent") : nil
        if shownSymbol != .some(symbol) {
            shownSymbol = .some(symbol)
            if let symbol {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                image?.isTemplate = true
                button.image = image?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
                button.imagePosition = .imageLeading
            } else {
                button.image = nil
                button.imagePosition = .noImage
            }
        }
        let text = model.menuBarText
        guard text != shownText else { return }
        shownText = text
        button.title = text
        button.toolTip = model.reading.map { Units.tooltip(for: $0) }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: Right-click menu

    /// A right-click, a two-finger click or a Control-click: the reading as a
    /// line to read, then Settings, About and Quit.
    private func showMenu() {
        // The outside-click monitor leaves status item clicks alone, so this
        // one would otherwise open the menu over the popover.
        if popover.isShown { closePopover(returningFocus: true) }

        let menu = NSMenu()
        for line in Self.readingLines(for: model.reading) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if let release = updates?.available {
            menu.addItem(withTitle: "Update Available: \(release.version)…", action: #selector(menuUpdate), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Export History…", action: #selector(menuExport), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "About Battery Trace", action: #selector(menuAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Battery Trace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp

        item.menu = menu
        item.button?.performClick(nil)
        // Detached at once, so the next left-click opens the popover, not the menu.
        item.menu = nil
    }

    /// "64% · On battery, about 5:37 left" and "Using 5.3 W" style lines.
    static func readingLines(for reading: LiveReading?) -> [String] {
        guard let reading else { return [] }
        let battery = reading.battery
        var lines: [String] = []
        if let percent = battery.percent {
            var state = battery.isOnExternalPower ? (battery.isCharging ? "Charging" : "On power adapter") : "On battery"
            if !battery.isOnExternalPower, let minutes = battery.minutesToEmpty {
                state += ", about \(Units.duration(minutes: minutes)) left"
            }
            lines.append("\(Int(percent.rounded()))% · \(state)")
        }
        if let watts = reading.systemWatts {
            lines.append(battery.isPresent && !battery.isOnExternalPower ? "Using \(Units.watts(watts)) from the battery" : "Drawing \(Units.watts(watts))")
        }
        return lines
    }

    @objc private func menuSettings() { openSettings() }
    @objc private func menuAbout() { openAbout() }
    @objc private func menuExport() { exportHistory() }
    @objc private func menuCheckForUpdates() { updates?.check(interactive: true) }
    @objc private func menuUpdate() { updates?.showAvailable() }

    // MARK: Popover

    func togglePopover() {
        popover.isShown ? closePopover(returningFocus: true) : showPopover()
    }

    func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        let root = PopoverView(model: model, openSettings: { [weak self] in self?.openSettings() })
        let hosting = NSHostingController(rootView: root)
        // Set before assigning: assigning loads the view and measures it, so
        // the popover is placed at its real size rather than a 320 pt default.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        model.popoverWillShow()

        if !NSApp.isActive, openSettingsWindow() != nil {
            appUnderPopover = NSWorkspace.shared.frontmostApplication
        }
        if let anchor = anchorView(under: button) {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // An accessory app isn't active by default; without this the popover
        // renders unfocused and swallows the first click.
        activateForPopover()
        clearInitialFocus()

        // Clicks in other apps, the menu bar included. A click on the status
        // item itself is left to `statusItemClicked`, which toggles.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown, !self.pointerIsOnStatusItem else { return }
                DispatchQueue.main.async { self.closePopover() }
            }
        }
    }

    var isPopoverShown: Bool { popover.isShown }

    /// `returningFocus` is for the popover being dismissed (Esc, or the item
    /// clicked again): if it opened over another app with Settings open
    /// behind, focus goes back to that app rather than to a window nobody can see.
    func closePopover(returningFocus: Bool = false) {
        guard popover.isShown else { return }
        let returnTo = returningFocus && NSApp.isActive ? appUnderPopover : nil
        appUnderPopover = nil
        closingPopover = true
        if NSApp.isActive {
            keepingSettingsInPlace { popover.performClose(nil) }
        } else {
            popover.performClose(nil)
        }
        closingPopover = false
        returnTo?.activate(options: [])
    }

    /// Esc closes the popover without going through `closePopover`: send it
    /// back through, a turn later rather than from inside AppKit's own close.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard !closingPopover else { return true }
        DispatchQueue.main.async { [weak self] in self?.closePopover(returningFocus: true) }
        return false
    }

    /// Every way the popover closes ends here, so none skips the bookkeeping.
    func popoverWillClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        stopWatchingMenuBar()
        anchorWindow?.orderOut(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        model.popoverDidClose()
        AppIcons.shared.purge()
    }

    /// Opens with nothing focused: otherwise the first control wears a focus
    /// ring nobody asked for. Tab still reaches it. Deferred, since SwiftUI
    /// assigns focus after the window is shown.
    private func clearInitialFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    private var pointerIsOnStatusItem: Bool {
        guard let frame = item.button?.window?.frame else { return false }
        // `NSMouseInRect`, not `contains`: the item's top row reports y == maxY.
        return NSMouseInRect(NSEvent.mouseLocation, frame, false)
    }

    /// An invisible window parked exactly where the status item is.
    ///
    /// `NSPopover` re-anchors to its positioning view whenever its content
    /// size changes. With an auto-hidden menu bar the item may be gone by
    /// then, and the popover jumps to the screen's left edge. The item's
    /// position is read at click time, the one moment it's on screen.
    private func anchorView(under button: NSStatusBarButton) -> NSView? {
        guard let itemWindow = button.window else { return nil }
        let rect = itemWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        let window = anchorWindow ?? {
            let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
            anchorWindow = w
            return w
        }()
        window.setFrame(rect, display: false)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: rect.size))
        window.orderFrontRegardless()
        return window.contentView
    }

    /// Activates the app for the popover, leaving Settings where it was.
    private func activateForPopover() {
        if !NSApp.isActive { activatingForPopover = true }
        keepingSettingsInPlace { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Runs `change` without letting it bring Settings forward from behind
    /// another app's window: activating makes Settings main, which orders it
    /// front. Off screen for that moment, it is left alone, then put back below
    /// the window that was in front of it.
    private func keepingSettingsInPlace(_ change: () -> Void) {
        guard let window = openSettingsWindow(), let inFront = WindowStack.window(inFrontOf: window.windowNumber) else {
            change()
            return
        }
        window.orderOut(nil)
        change()
        window.order(.below, relativeTo: inFront)
    }

    // MARK: Auto-hidden menu bar

    /// An accessory app has no menu bar, so when the pointer reveals a hidden
    /// one, macOS activates an app that has one. Losing focus with the pointer
    /// up in the menu bar is that, and the popover rides it out. Losing it
    /// anywhere else (⌘-Tab, Spotlight) is a real switch, and closes it.
    @objc private func appDidResignActive() {
        guard popover.isShown else { return }
        if pointerIsInMenuBar {
            restoreFocusWhenMenuBarHides()
        } else {
            closePopover()
        }
    }

    /// Hands focus back to the popover once the pointer leaves the menu bar,
    /// unless the user switched to another app meanwhile: then it closes.
    private func restoreFocusWhenMenuBarHides() {
        guard menuBarMonitors.isEmpty else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let revealedFor = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pointerMoved = { [weak self] in
            guard let self, !self.pointerIsInMenuBar else { return }
            self.stopWatchingMenuBar()
            guard self.popover.isShown else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let switchedAway = revealedFor.map { $0 != ownPID && frontmost != $0 } ?? false
            if switchedAway { self.closePopover() } else { self.activateForPopover() }
        }
        // Both: leaving over another app's window reaches only the global
        // monitor, leaving straight down into the popover only the local one.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in
            MainActor.assumeIsolated { pointerMoved() }
        }) {
            menuBarMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            MainActor.assumeIsolated { pointerMoved() }
            return event
        }) {
            menuBarMonitors.append(local)
        }
    }

    /// Back to the app by ⌘-Tab, the Dock or a click on Settings while it's
    /// open: Settings alone, made key.
    @objc private func appDidBecomeActive() {
        guard !activatingForPopover else {
            activatingForPopover = false
            return
        }
        guard let window = openSettingsWindow(), NSApp.modalWindow == nil else { return }
        if popover.isShown { closePopover() }
        window.makeKeyAndOrderFront(nil)
    }

    private func stopWatchingMenuBar() {
        menuBarMonitors.forEach(NSEvent.removeMonitor)
        menuBarMonitors.removeAll()
    }

    private var pointerIsInMenuBar: Bool {
        MenuBarStrip.contains(NSEvent.mouseLocation, screens: NSScreen.screens.map { ($0.frame, menuBarHeight(on: $0)) })
    }

    func menuBarHeight(on screen: NSScreen) -> CGFloat {
        MenuBarStrip.height(statusItemThickness: NSStatusBar.system.thickness,
                            statusItemWindowHeight: item.button?.window?.frame.height,
                            safeAreaTop: screen.safeAreaInsets.top)
    }
}

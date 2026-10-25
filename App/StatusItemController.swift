import AppKit
import SwiftUI

/// The menu bar item and its popover.
///
/// The button's title is set only when its text changes. The popover's
/// SwiftUI content is created when it opens and released when it closes, so a
/// closed popover holds no view hierarchy and does no layout.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let openSettings: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var shownText = ""
    private var shownStyle: SettingsStore.MenuBarStyle?

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("Battery Trace")
        }
        model.onMenuBarChange = { [weak self] in self?.updateButton() }
        updateButton()
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let style = model.settings.menuBarStyle
        if style != shownStyle {
            shownStyle = style
            let symbol = style == .watts ? "bolt.fill" : "battery.75percent"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }
        let text = model.menuBarText
        guard text != shownText else { return }
        shownText = text
        button.title = text
        button.toolTip = model.reading.map { Units.tooltip(for: $0) }
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    func showPopover() {
        guard let button = item.button else { return }
        let root = PopoverView(model: model, openSettings: { [weak self] in
            self?.popover.performClose(nil)
            self?.openSettings()
        })
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        model.popoverWillShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        model.popoverDidClose()
        AppIcons.shared.purge()
    }
}

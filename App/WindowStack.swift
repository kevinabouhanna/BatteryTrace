import AppKit

/// Where a window sits among every app's windows, front to back.
///
/// Activating the app for the popover brings Settings forward over the app the
/// user is in. Putting it back means ordering it below the window that was in
/// front of it, which is usually another app's, so only the window server
/// knows it.
enum WindowStack {
    /// The window directly in front of `window` on its layer, or nil when it's
    /// frontmost or off screen.
    static func window(inFrontOf window: Int) -> Int? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let stack = info.compactMap { entry -> (number: Int, layer: Int)? in
            guard let number = entry[kCGWindowNumber as String] as? Int, let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            return (number, layer)
        }
        guard let index = stack.firstIndex(where: { $0.number == window }) else { return nil }
        let layer = stack[index].layer
        return stack[..<index].last(where: { $0.layer == layer })?.number
    }
}

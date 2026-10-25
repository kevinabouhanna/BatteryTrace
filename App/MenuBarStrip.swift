import CoreGraphics

/// Where the menu bar is, whether or not it's showing. Pure, so it can be
/// reasoned about without a screen.
enum MenuBarStrip {
    /// The menu bar's height on a screen. Three readings, the largest wins:
    /// the status bar's thickness (22 pt), the status item's window (taller on
    /// macOS 26 and later, 30 pt on 27), and the notch's safe area.
    static func height(statusItemThickness: CGFloat, statusItemWindowHeight: CGFloat?, safeAreaTop: CGFloat) -> CGFloat {
        max(statusItemThickness, statusItemWindowHeight ?? 0, safeAreaTop)
    }

    /// Whether `point` is in the top strip of the screen it's on.
    static func contains(_ point: CGPoint, screens: [(frame: CGRect, menuBarHeight: CGFloat)]) -> Bool {
        guard let screen = screens.first(where: { isOnScreen(point, $0.frame) }) else { return false }
        return point.y >= screen.frame.maxY - screen.menuBarHeight
    }

    private static func isOnScreen(_ point: CGPoint, _ frame: CGRect) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
    }
}

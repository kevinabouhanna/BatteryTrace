import AppKit
import BatteryTraceCore

/// Small app icons for the Apps list. `NSWorkspace` icons carry every size up
/// to 1024 px; each is redrawn once at 32 px and only that is kept, and the
/// cache is emptied when the popover closes.
@MainActor
final class AppIcons {
    static let shared = AppIcons()
    private var cache: [AppKey: NSImage] = [:]

    func icon(for identity: AppIdentity) -> NSImage {
        if let cached = cache[identity.key] { return cached }
        let image: NSImage
        if let path = identity.key.bundlePath {
            image = Self.downsized(NSWorkspace.shared.icon(forFile: path))
        } else {
            let symbol = switch identity.kind {
            case .kernel: "cpu"
            case .system: "gearshape"
            case .app, .other: "terminal"
            }
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
            image.isTemplate = true
        }
        cache[identity.key] = image
        return image
    }

    func purge() { cache.removeAll() }

    private static func downsized(_ icon: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let small = NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }
        // Rasterise now at 2×, so the full-size representations can go.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return small }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        small.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(bitmap)
        return result
    }
}

import BatteryTraceCore
import CoreGraphics
import Foundation
import IOKit

/// The built-in display's backlight: brightness, and a model of its power.
///
/// No sensor measures panel power, so this is always an **estimate**:
///
///     watts ≈ scale × (−0.085·s + 5.12·s²)      s = brightness slider, 0…1
///
/// The curve was fitted on a MacBook Air (M1, 2020) by stepping the slider
/// with the Mac idle and watching the system power sensor, with the chip's own
/// measured energy subtracted (`DisplayCalibrator`): about 5 W at full
/// brightness, 1.2 W at half. Other panels are scaled by peak brightness ×
/// area relative to that one, which is rough, until the Mac measures its own
/// panel (Settings › General › Display › Calibrate…); then its own curve is
/// used, unscaled. Power that doesn't change with brightness (the panel's
/// electronics) can't be separated from the rest of the Mac, so it stays in
/// Unattributed.
///
/// The slider comes from `DisplayServicesGetBrightness` (private), because on
/// Apple silicon every brightness figure in the IORegistry
/// (`AppleARMBacklight` → `IODisplayParameters`) stays frozen while the
/// slider moves. Those are only the fallback.
public final class DisplayBacklightSource: ComponentSource, SnapshotSource {
    public let sourceName = "Display"
    public private(set) var isAvailable = false
    public private(set) var diagnostics: [String] = []

    /// The panel the reference curve was fitted on: 420 nits, 286.9 × 179.3 mm.
    static let referencePeakNits = 420.0
    static let referenceAreaMM2 = 286.87 * 179.29

    /// The reference curve's scale for this panel, by peak brightness × area.
    private let panelScale: Double
    private var curve = BacklightCurve.reference
    private var scale: Double
    /// Set when this Mac measured its own panel (Settings › Calibrate…).
    public private(set) var calibration: DisplayCalibration?
    private let backlight: io_registry_entry_t
    private var lastWatts: Double?
    private var hasBaseline = false

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private let getBrightness: GetBrightness?
    private let builtInDisplay: CGDirectDisplayID?

    public init() {
        backlight = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"))
        let services = PrivateSymbols.open("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
        getBrightness = PrivateSymbols.function("DisplayServicesGetBrightness", in: services, as: GetBrightness.self)

        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success {
            builtInDisplay = ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
        } else {
            builtInDisplay = nil
        }

        // Scale the reference curve by this panel's peak brightness × area.
        var panelScale = 1.0
        if let display = builtInDisplay {
            let size = CGDisplayScreenSize(display)
            let area = Double(size.width * size.height)
            let nits = Self.peakNits(backlight) ?? Self.referencePeakNits
            if area > 0 { panelScale = min(4, max(0.5, (nits * area) / (Self.referencePeakNits * Self.referenceAreaMM2))) }
        }
        self.panelScale = panelScale
        scale = panelScale

        if builtInDisplay == nil {
            diagnostics.append("no built-in display: no display power estimate")
        } else if getBrightness == nil, backlight == 0 {
            diagnostics.append("no brightness reading: no display power estimate")
        } else {
            isAvailable = true
            diagnostics.append(String(format: "brightness from %@; model ≈ %.2f W at full brightness (estimate, scale %.2f)",
                                      getBrightness != nil ? "DisplayServices" : "IORegistry (may be stale)",
                                      curve.watts(slider: 1) * scale, scale))
        }
    }

    deinit {
        if backlight != 0 { IOObjectRelease(backlight) }
    }

    static func watts(slider s: Double, scale: Double) -> Double {
        scale * BacklightCurve.reference.watts(slider: s)
    }

    /// Uses this Mac's own measured curve, or the reference scaled to this
    /// panel when `calibration` is nil or untrustworthy.
    public func use(_ calibration: DisplayCalibration?) {
        if let calibration, calibration.isTrustworthy {
            self.calibration = calibration
            curve = calibration.curve
            scale = 1
        } else {
            self.calibration = nil
            curve = .reference
            scale = panelScale
        }
    }

    private func watts(slider s: Double) -> Double { scale * curve.watts(slider: s) }

    /// The slider position, 0…1, or nil if the panel is asleep or gone.
    /// A tick asks twice (energy, then the System section); the second
    /// answer is reused rather than asking the window server again.
    public func brightness() -> Double? {
        let now = Clock.uptimeNS()
        if let cached = lastBrightness, now &- cached.at < 500_000_000 { return cached.value }
        let value = readBrightness()
        lastBrightness = (now, value)
        return value
    }

    private var lastBrightness: (at: UInt64, value: Double?)?

    private func readBrightness() -> Double? {
        guard let display = builtInDisplay, CGDisplayIsActive(display) != 0, CGDisplayIsAsleep(display) == 0 else { return nil }
        if let getBrightness {
            var value: Float = 0
            if getBrightness(display, &value) == 0, value.isFinite { return Double(min(1, max(0, value))) }
        }
        return Self.registryFraction(backlight, key: "brightness")
    }

    /// The model's backlight power right now. 0 when the panel is off.
    public func estimatedWatts() -> Double {
        brightness().map { watts(slider: $0) } ?? 0
    }

    public func resetBaseline() { hasBaseline = false }

    /// Energy over the interval, from the average of the model at its two
    /// ends. Brightness rarely changes mid-interval, so that is close enough.
    public func readComponents(intervalSeconds: Double, into out: inout [ComponentEnergy]) {
        guard isAvailable else { return }
        let watts = estimatedWatts()
        defer {
            lastWatts = watts
            hasBaseline = true
        }
        guard hasBaseline, let last = lastWatts, intervalSeconds > 0 else { return }
        out.append(ComponentEnergy(id: .displayBacklight, joules: (watts + last) / 2 * intervalSeconds, provenance: .estimated))
    }

    public func update(_ snapshot: inout SystemSnapshot) {
        var display = DisplaySnapshot()
        display.brightness = brightness()
        display.estimatedBacklightWatts = isAvailable ? display.brightness.map { watts(slider: $0) } ?? 0 : nil
        display.calibratedOnThisMac = calibration != nil
        snapshot.display = display
    }

    private static func peakNits(_ backlight: io_registry_entry_t) -> Double? {
        guard backlight != 0,
              let parameters = IORegistryEntryCreateCFProperty(backlight, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? NSDictionary,
              let nits = parameters["BrightnessMilliNits"] as? NSDictionary,
              let max = (nits["max"] as? NSNumber)?.doubleValue, max > 0
        else { return nil }
        return max / 1000
    }

    private static func registryFraction(_ backlight: io_registry_entry_t, key: String) -> Double? {
        guard backlight != 0,
              let parameters = IORegistryEntryCreateCFProperty(backlight, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? NSDictionary,
              let entry = parameters[key] as? NSDictionary,
              let value = (entry["value"] as? NSNumber)?.doubleValue,
              let max = (entry["max"] as? NSNumber)?.doubleValue, max > 0
        else { return nil }
        return min(1, Swift.max(0, value / max))
    }
}

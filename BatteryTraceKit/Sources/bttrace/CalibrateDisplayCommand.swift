import Foundation
import PowerSources

/// Fits this Mac's backlight curve, as Settings › Calibrate… does. Changes
/// the built-in display's brightness for about a minute, then puts it back.
enum CalibrateDisplayCommand {
    static func run(_ arguments: inout Arguments) {
        let settle = arguments.double("--settle", default: 5)
        let measure = arguments.double("--measure", default: 6)
        guard let calibrator = DisplayCalibrator() else {
            print("This Mac can't be calibrated: it needs a built-in display, brightness control and the SMC power sensor.")
            return
        }
        print("Stepping brightness \(DisplayCalibrator.levels.map { String(format: "%.2f", $0) }.joined(separator: " → ")); keep the Mac idle.")
        guard let result = calibrator.run(settle: settle, measure: measure, progress: { step, steps in print("  step \(step) of \(steps)") }) else {
            print("Calibration failed.")
            return
        }
        print(String(format: "Fit: rest ≈ %.2f + %.2f·s + %.2f·s²  (fit quality %.2f)", result.interceptWatts, result.curve.linear,
                     result.curve.quadratic, result.fitQuality))
        print(String(format: "Backlight ≈ %.2f W at full brightness. %@", result.curve.watts(slider: 1),
                     result.isTrustworthy ? "Trustworthy." : "Too noisy to use: run it again with the Mac idle."))
    }
}

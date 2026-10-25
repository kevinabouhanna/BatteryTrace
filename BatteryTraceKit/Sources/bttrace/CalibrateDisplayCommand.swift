import BatteryTraceCore
import CoreGraphics
import Foundation
import IOKit
import PowerSources

/// Fits `rest = a + b·s + c·s²` (s = brightness slider) by stepping the
/// built-in display's brightness and watching the system power sensor, with
/// the SoC's own measured energy subtracted so CPU noise doesn't land in the
/// fit. `b` and `c` are `DisplayBacklightSource.referenceCurve`.
///
/// Also prints the IORegistry's brightness figures at each step, which on
/// Apple silicon stay frozen: the reason the model uses the slider.
///
/// Changes the brightness for about a minute, then puts it back, also on ^C.
enum CalibrateDisplayCommand {
    typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    nonisolated(unsafe) static var restore: (SetBrightness, UInt32, Float)?

    static func run(_ arguments: inout Arguments) {
        let settle = arguments.double("--settle", default: 5)
        let measure = arguments.double("--measure", default: 6)
        let levels: [Float] = [0.05, 0.25, 0.5, 0.75, 1.0, 0.75, 0.5, 0.25, 0.05]

        let services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        guard let get = dlsym(services, "DisplayServicesGetBrightness").map({ unsafeBitCast($0, to: GetBrightness.self) }),
              let set = dlsym(services, "DisplayServicesSetBrightness").map({ unsafeBitCast($0, to: SetBrightness.self) })
        else { print("DisplayServices unavailable"); return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        guard let display = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { print("no built-in display"); return }
        var original: Float = 0
        guard get(display, &original) == 0 else { print("can't read brightness"); return }
        restore = (set, display, original)
        signal(SIGINT) { _ in
            if let (set, display, value) = CalibrateDisplayCommand.restore { _ = set(display, value) }
            exit(130)
        }
        defer { _ = set(display, original); print(String(format: "Brightness restored to %.2f", original)) }

        let smc = SMCSystemPowerSource()
        let soc = IOReportComponentSource()
        let backlight = DisplayBacklightSource()
        guard smc.isAvailable else { print("needs the SMC power sensor"); return }
        _ = backlight

        print("Stepping brightness \(levels.map { String(format: "%.1f", $0) }.joined(separator: " → ")); keep the Mac idle.")
        var sliderPoints: [(slider: Double, rest: Double)] = []
        let backlightService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"))
        func registry(_ key: String) -> String {
            guard let p = IORegistryEntryCreateCFProperty(backlightService, "IODisplayParameters" as CFString, nil, 0)?.takeRetainedValue() as? NSDictionary,
                  let d = p[key] as? NSDictionary, let v = (d["value"] as? NSNumber)?.doubleValue, let m = (d["max"] as? NSNumber)?.doubleValue, m > 0 else { return "-" }
            return String(format: "%.3f", v / m)
        }
        for level in levels {
            _ = set(display, level)
            Thread.sleep(forTimeInterval: settle)
            var readings: [Double] = []
            var socJoules = 0.0
            var components: [ComponentEnergy] = []
            soc.readComponents(intervalSeconds: 0, into: &components) // baseline
            let start = Clock.uptimeNS()
            while Double(Clock.uptimeNS() - start) / 1e9 < measure {
                Thread.sleep(forTimeInterval: 0.5)
                if let watts = smc.readSystemWatts() { readings.append(watts) }
            }
            components.removeAll()
            soc.readComponents(intervalSeconds: measure, into: &components)
            socJoules = components.reduce(0) { $0 + $1.joules }
            let seconds = Double(Clock.uptimeNS() - start) / 1e9
            let system = readings.sorted()[readings.count / 2]
            let socWatts = socJoules / seconds
            sliderPoints.append((Double(level), system - socWatts))
            print(String(format: "  slider %.2f  system %.2f W  SoC %.2f W  rest %.2f W   registry: brightness %@ current %@ nits %@",
                         level, system, socWatts, system - socWatts,
                         registry("brightness"), registry("BrightnessMicroAmps"), registry("BrightnessMilliNits")))
        }

        // Least squares rest = a + b·s + c·s².
        do {
            var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
            var v = [Double](repeating: 0, count: 3)
            for p in sliderPoints {
                let basis = [1, p.slider, p.slider * p.slider]
                for i in 0..<3 { v[i] += basis[i] * p.rest; for j in 0..<3 { m[i][j] += basis[i] * basis[j] } }
            }
            if let coefficients = solve3(m, v) {
                let (a, b, c) = (coefficients[0], coefficients[1], coefficients[2])
                let residual = sliderPoints.reduce(0.0) { $0 + pow($1.rest - (a + b * $1.slider + c * $1.slider * $1.slider), 2) }
                let total = sliderPoints.reduce(0.0) { $0 + pow($1.rest - sliderPoints.reduce(0) { $0 + $1.rest } / Double(sliderPoints.count), 2) }
                print(String(format: "\nSlider fit: rest ≈ %.2f + %.2f·s + %.2f·s²  (R² = %.3f). Backlight at full slider ≈ %.2f W over minimum.",
                             a, b, c, total > 0 ? 1 - residual / total : 0, b + c))
            }
        }
    }
}

/// Solves a 3×3 linear system by Cramer's rule. Nil if singular.
func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
    func det(_ a: [[Double]]) -> Double {
        a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
    }
    let d = det(m)
    guard abs(d) > 1e-12 else { return nil }
    return (0..<3).map { column in
        var replaced = m
        for row in 0..<3 { replaced[row][column] = v[row] }
        return det(replaced) / d
    }
}

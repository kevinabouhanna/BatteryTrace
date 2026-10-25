import BatteryTraceCore
import CoreGraphics
import Foundation

/// The backlight curve, in watts, for a brightness slider position s:
/// `linear·s + quadratic·s²`. Zero at s = 0.
public struct BacklightCurve: Sendable, Codable, Equatable {
    public var linear: Double
    public var quadratic: Double

    public init(linear: Double, quadratic: Double) {
        self.linear = linear
        self.quadratic = quadratic
    }

    public func watts(slider s: Double) -> Double { max(0, linear * s + quadratic * s * s) }

    /// Fitted on a MacBook Air (M1, 2020), the mean of two quiet runs (fit
    /// quality 0.99 each); other panels scale it. Convex: the slider is
    /// perceptual, so half brightness draws far less than half the power
    /// (the backlight current read 7.5% of its maximum at half).
    public static let reference = BacklightCurve(linear: -0.085, quadratic: 5.12)
}

/// A finished calibration of this Mac's built-in display.
public struct DisplayCalibration: Sendable, Codable, Equatable {
    public var curve: BacklightCurve
    /// Power that doesn't change with brightness, at the fit's intercept.
    public var interceptWatts: Double
    /// How well the curve fits the measurements, 0…1.
    public var fitQuality: Double
    public var date: Date

    /// Below this the measurement was too noisy to trust.
    public static let minimumFitQuality = 0.6
    public var isTrustworthy: Bool { fitQuality >= Self.minimumFitQuality && curve.watts(slider: 1) > 0.2 }
}

/// Measures this Mac's backlight: steps the built-in display's brightness,
/// watching the system power sensor with the chip's own measured energy
/// subtracted, and fits `rest = a + b·s + c·s²`.
///
/// Changes the brightness for about a minute and always puts it back,
/// cancelled or not. Blocking: run it off the main thread.
public final class DisplayCalibrator {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    public static let levels: [Float] = [0.05, 0.25, 0.5, 0.75, 1.0, 0.75, 0.5, 0.25, 0.05]

    private let get: GetBrightness
    private let set: SetBrightness
    private let display: CGDirectDisplayID
    private let sensor: SMCSystemPowerSource

    /// Nil when this Mac can't be calibrated: no built-in display, no
    /// brightness control, or no system power sensor.
    public init?() {
        let services = PrivateSymbols.open("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
        guard let get = PrivateSymbols.function("DisplayServicesGetBrightness", in: services, as: GetBrightness.self),
              let set = PrivateSymbols.function("DisplayServicesSetBrightness", in: services, as: SetBrightness.self)
        else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        guard let display = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        let sensor = SMCSystemPowerSource()
        guard sensor.isAvailable else { return nil }
        self.get = get
        self.set = set
        self.display = display
        self.sensor = sensor
    }

    /// Runs the measurement. `progress` gets the step just finished and the
    /// number of steps; `cancelled` is asked before each step.
    public func run(settle: Double = 5, measure: Double = 6,
                    progress: (Int, Int) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) -> DisplayCalibration? {
        var original: Float = 0
        guard get(display, &original) == 0 else { return nil }
        defer { _ = set(display, original) }
        let chip = IOReportComponentSource()
        var points: [(slider: Double, rest: Double)] = []
        for (index, level) in Self.levels.enumerated() {
            if cancelled() { return nil }
            _ = set(display, level)
            Thread.sleep(forTimeInterval: settle)
            var components: [ComponentEnergy] = []
            chip.readComponents(intervalSeconds: 0, into: &components)
            components.removeAll()
            let start = Clock.uptimeNS()
            var readings: [Double] = []
            while Double(Clock.uptimeNS() - start) / 1e9 < measure {
                Thread.sleep(forTimeInterval: 0.5)
                if let watts = sensor.readSystemWatts() { readings.append(watts) }
            }
            chip.readComponents(intervalSeconds: measure, into: &components)
            let seconds = Double(Clock.uptimeNS() - start) / 1e9
            guard !readings.isEmpty else { return nil }
            let system = readings.sorted()[readings.count / 2]
            let chipWatts = components.reduce(0) { $0 + $1.joules } / seconds
            points.append((Double(level), system - chipWatts))
            progress(index + 1, Self.levels.count)
        }
        return Self.fit(points, date: Date())
    }

    /// Least squares `rest = a + b·s + c·s²`. Pure.
    public static func fit(_ points: [(slider: Double, rest: Double)], date: Date = Date()) -> DisplayCalibration? {
        guard points.count >= 3 else { return nil }
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var v = [0.0, 0.0, 0.0]
        for p in points {
            let basis = [1, p.slider, p.slider * p.slider]
            for i in 0..<3 {
                v[i] += basis[i] * p.rest
                for j in 0..<3 { m[i][j] += basis[i] * basis[j] }
            }
        }
        guard let c = solve(m, v) else { return nil }
        let mean = points.reduce(0) { $0 + $1.rest } / Double(points.count)
        let residual = points.reduce(0) { $0 + pow($1.rest - (c[0] + c[1] * $1.slider + c[2] * $1.slider * $1.slider), 2) }
        let total = points.reduce(0) { $0 + pow($1.rest - mean, 2) }
        return DisplayCalibration(curve: BacklightCurve(linear: c[1], quadratic: c[2]), interceptWatts: c[0],
                                  fitQuality: total > 0 ? max(0, 1 - residual / total) : 0, date: date)
    }

    /// A 3×3 linear system by Cramer's rule; nil if singular.
    static func solve(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        return (0..<3).map { column in
            var replaced = m
            for row in 0..<3 { replaced[row][column] = v[row] }
            return det(replaced) / d
        }
    }
}

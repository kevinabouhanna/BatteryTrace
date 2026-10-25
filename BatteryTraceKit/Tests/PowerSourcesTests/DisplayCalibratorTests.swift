@testable import PowerSources
import Testing

@Suite struct DisplayCalibratorTests {
    @Test func anExactCurveIsRecovered() throws {
        let curve = BacklightCurve(linear: 4.2, quadratic: -0.9)
        let points = DisplayCalibrator.levels.map { level in (slider: Double(level), rest: 1.3 + curve.watts(slider: Double(level))) }
        let fit = try #require(DisplayCalibrator.fit(points))
        #expect(abs(fit.curve.linear - 4.2) < 1e-6)
        #expect(abs(fit.curve.quadratic + 0.9) < 1e-6)
        #expect(abs(fit.interceptWatts - 1.3) < 1e-6)
        #expect(fit.fitQuality > 0.999)
        #expect(fit.isTrustworthy)
    }

    @Test func noiseThatSwampsTheBrightnessIsNotTrusted() throws {
        // Rest power that doesn't follow brightness at all.
        let rest = [3.1, 2.2, 4.0, 2.5, 3.6, 2.0, 3.9, 2.4, 3.0]
        let points = zip(DisplayCalibrator.levels, rest).map { (slider: Double($0), rest: $1) }
        let fit = try #require(DisplayCalibrator.fit(points))
        #expect(!fit.isTrustworthy)
    }

    @Test func theReferenceCurveIsAboutFiveWattsAtFullBrightnessAndConvex() {
        #expect(abs(BacklightCurve.reference.watts(slider: 1) - 5.035) < 0.01)
        #expect(BacklightCurve.reference.watts(slider: 0) == 0)
        // Half the slider is well under half the power.
        #expect(BacklightCurve.reference.watts(slider: 0.5) < BacklightCurve.reference.watts(slider: 1) / 3)
    }
}

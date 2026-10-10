import SwiftUI
import Testing
@testable import SimpleMediaPlayer

struct VUMeterScaleTests {
    @Test func needlePositionMapsReferenceAndClampsEndpoints() {
        #expect(VUMeterScale.needlePosition(normalizedRMS: 0) == 0)
        #expect(abs(VUMeterScale.needlePosition(normalizedRMS: (-18 + 60) / 60) - 0.78) < 0.001)
        #expect(VUMeterScale.needlePosition(normalizedRMS: (-38 + 60) / 60) == 0)
        #expect(VUMeterScale.needlePosition(normalizedRMS: (-15 + 60) / 60) == 1)
        #expect(VUMeterScale.needlePosition(normalizedRMS: 1) == 1)
        #expect(VUMeterScale.needlePosition(normalizedRMS: 2) == 1)
        #expect(VUMeterScale.needlePosition(normalizedRMS: -1) == 0)
    }

    @Test func needlePositionInterpolatesBetweenTicks() {
        let normalizedRMS: Float = (-33 + 60) / 60
        #expect(abs(VUMeterScale.needlePosition(normalizedRMS: normalizedRMS) - 0.115) < 0.001)
        for tick in VUMeterScale.ticks {
            let rms = (tick.vu + VUMeterScale.referenceLevelDBFS + 60) / 60
            #expect(abs(VUMeterScale.needlePosition(normalizedRMS: rms) - tick.t) < 0.001)
        }
    }

    @Test func angleSpansTheDesignedArc() {
        #expect(VUMeterScale.angleDegrees(for: 0) == -47)
        #expect(VUMeterScale.angleDegrees(for: 1) == 47)
    }

    @Test func ballisticsSettlesWithinOneSecond() {
        var ballistics = VUMeterScale.Ballistics()
        for _ in 0..<60 {
            ballistics.step(toward: 0.8, dt: 1.0 / 60)
        }
        #expect(abs(ballistics.position - 0.8) < 0.01)
    }

    @Test(arguments: [10, 30, 60])
    func stoppedNeedleSettlesBeforeDrawingIsPaused(framesPerSecond: Int) {
        var ballistics = VUMeterScale.Ballistics(position: 1, velocity: 10)
        let frames = Int(VUMeterScale.settlingDuration * Double(framesPerSecond))
        for _ in 0..<frames {
            ballistics.step(toward: 0, dt: 1 / Float(framesPerSecond))
        }
        #expect(abs(ballistics.position) < 0.005)
        #expect(abs(ballistics.velocity) < 0.05)
    }

    @Test func ballisticsClampsLongIntervalsAndStaysFinite() {
        var ballistics = VUMeterScale.Ballistics()
        var clamped = VUMeterScale.Ballistics()
        for _ in 0..<600 {
            ballistics.step(toward: 0.8, dt: 1)
            clamped.step(toward: 0.8, dt: VUMeterScale.Ballistics.maximumElapsedTime)
            #expect(ballistics.position.isFinite)
            #expect(ballistics.velocity.isFinite)
            #expect(ballistics.position == clamped.position)
            #expect(ballistics.velocity == clamped.velocity)
        }
        var unchanged = VUMeterScale.Ballistics(position: 0.4, velocity: 1)
        unchanged.step(toward: 1, dt: -1)
        #expect(unchanged.position == 0.4)
        #expect(unchanged.velocity == 1)
    }

    /// The slow response mode draws at 10 fps; its needle must rise in the same real time as at 60 fps.
    @Test(arguments: [10, 30, 60])
    func ballisticsFollowRealTimeAtEveryFrameRate(framesPerSecond: Int) {
        var reference = VUMeterScale.Ballistics()
        var ballistics = VUMeterScale.Ballistics()
        let substepsPerFrame = 60 / framesPerSecond
        for _ in 0..<framesPerSecond {
            ballistics.step(toward: 0.8, dt: 1 / Float(framesPerSecond))
            for _ in 0..<substepsPerFrame {
                reference.step(toward: 0.8, dt: 1.0 / 60)
            }
            #expect(abs(ballistics.position - reference.position) < 0.0001)
            #expect(abs(ballistics.velocity - reference.velocity) < 0.001)
        }
        // Half a second reaches most of the way, as the 60 fps needle does.
        var risen = VUMeterScale.Ballistics()
        for _ in 0..<(framesPerSecond / 2) {
            risen.step(toward: 0.8, dt: 1 / Float(framesPerSecond))
        }
        #expect(risen.position > 0.75)
    }

    @Test func ivoryFaceUsesLightPalette() {
        let palette = VUMeterPalette.resolved(faceHex: "#E5E89D", lampHex: "#FFD9A0")
        #expect(!palette.isDarkFace)
        #expect(palette.glassIntensity == 0.7)
        #expect(palette.lampIntensity == 0.55)
        #expect(palette.ink == LEDColorValue.resolved("#2A2A1C").color)
        #expect(palette.red == LEDColorValue.resolved("#C8412E").color)
        #expect(palette.needle == LEDColorValue.resolved("#1A1A12").color)
        #expect(palette.wellShadow.contact == nil)
    }

    @Test func blackFaceUsesDarkPalette() {
        let palette = VUMeterPalette.resolved(faceHex: "#1C1D20", lampHex: "#FFD9A0")
        #expect(palette.isDarkFace)
        #expect(palette.glassIntensity == 0.3)
        #expect(palette.lampIntensity == 0.36)
        #expect(palette.ink == LEDColorValue.resolved("#E9E4CF").color)
        #expect(palette.red == LEDColorValue.resolved("#FF5A3C").color)
        #expect(palette.needle == LEDColorValue.resolved("#F2EEDC").color)
        #expect(palette.wellShadow.left.opacity == 0.92 * 0.75)
        #expect(palette.wellShadow.contact != nil)
    }

    @Test func invalidColorsUseIndependentVUDefaults() {
        let invalidFace = VUMeterPalette.resolved(faceHex: "zzz", lampHex: "#4DA3FF")
        #expect(invalidFace.faceColor == LEDColorValue.resolved("#E5E89D").color)
        #expect(invalidFace.lamp == LEDColorValue.resolved("#4DA3FF"))
        let invalidLamp = VUMeterPalette.resolved(faceHex: "#1C1D20", lampHex: "zzz")
        #expect(invalidLamp.lamp == LEDColorValue.resolved("#FFD9A0"))
        #expect(invalidLamp.face == LEDColorValue.resolved("#1C1D20"))
        #expect(invalidLamp.lampColor == LEDColorValue.resolved("#FFD9A0").color)
    }
}

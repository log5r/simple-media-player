import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct PitchEffectStreamingTests {
    private let irregularChunks = [1, 7, 64, 511, 4096, 13]

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0], [64, 4_800])
    func unityDrainsBothBoundaryImpulsesEvenWhenInputReportsSilence(sampleRate: Double, frameCount: Int) throws {
        let fixture = try PitchEffectRenderFixture(sampleRate: sampleRate, pitchCents: 0)
        var input = [Float](repeating: 0, count: frameCount)
        input[0] = 0.1
        input[frameCount - 1] = -0.08
        let result = try fixture.render(input, chunks: irregularChunks)

        #expect(fixture.latencyFrames > frameCount)
        #expect(fixture.audibleOutputAfterSilentInput)
        #expect(fixture.audibleOutputMarkedSilent == false)
        for (channel, samples) in result.enumerated() {
            #expect(samples.count == frameCount)
            let gain: Float = channel == 0 ? 1 : -0.8
            let maximumError = zip(samples, input).map { abs($0 - $1 * gain) }.max() ?? 0
            #expect(maximumError < 0.000_01)
        }
    }

    @Test(arguments: [AVAudioChannelCount(1), AVAudioChannelCount(2)])
    func transposedAudioDoesNotDependOnRenderBlockBoundaries(channels: AVAudioChannelCount) throws {
        let input = PitchEffectTestSignal.sine(frequency: 440, frames: 44_100)
        let fixture = try PitchEffectRenderFixture(channels: channels)
        let fixed = try fixture.render(input)
        fixture.effect.reset()
        let irregular = try fixture.render(input, chunks: irregularChunks)

        for channel in fixed.indices {
            let maximumDifference = zip(fixed[channel], irregular[channel]).map { abs($0 - $1) }.max() ?? 0
            #expect(maximumDifference < 0.000_01)
            #expect(irregular[channel].allSatisfy { $0.isFinite })
        }
    }

    @Test func resetDiscardsThePreviousTracksSamplesAndPhaseHistory() throws {
        let fixture = try PitchEffectRenderFixture()
        _ = try fixture.render(PitchEffectTestSignal.sine(frequency: 440, frames: 22_050))
        fixture.effect.reset()
        let next = PitchEffectTestSignal.sine(frequency: 880, frames: 22_050)
        let afterReset = try fixture.render(next, chunks: irregularChunks)
        let fresh = try PitchEffectRenderFixture()
        let expected = try fresh.render(next, chunks: irregularChunks)

        for channel in expected.indices {
            let maximumDifference = zip(afterReset[channel], expected[channel]).map { abs($0 - $1) }.max() ?? 0
            #expect(maximumDifference < 0.000_01)
        }
    }

    @Test func changingPitchAcrossUnityPreservesTheLatestRequestedPitch() throws {
        let fixture = try PitchEffectRenderFixture(pitchCents: 0)
        let input = PitchEffectTestSignal.sine(frequency: 440, frames: 44_100)
        for pitch in [Float(0), -300, 0] {
            // Several control-side updates before the next render must leave the
            // most recent pitch in effect, including a return to zero cents.
            fixture.effect.pitchCents = 300
            fixture.effect.pitchCents = pitch
            let output = try fixture.render(input, chunks: irregularChunks)
            let measured = try PitchEffectTestSignal.measuredFrequency(output[0].dropFirst(22_050), sampleRate: 44_100)
            let expected = 440 * pow(2, Double(pitch) / 1200)
            #expect(abs(1200 * log2(measured / expected)) < 1)
            #expect(output[0].allSatisfy { $0.isFinite })
        }
    }
}

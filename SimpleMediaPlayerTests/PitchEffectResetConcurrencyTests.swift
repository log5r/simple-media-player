import Foundation
import Testing
@testable import SimpleMediaPlayer

struct PitchEffectResetConcurrencyTests {
    @Test(arguments: [Float(0), -300])
    func resetDuringInputPullDiscardsOldInputBeforeStartingTheNextTrack(pitchCents: Float) throws {
        let fixture = try PitchEffectRenderFixture(pitchCents: pitchCents)
        var previous = [Float](repeating: 0, count: 512)
        previous[0] = 0.5

        // The pull starts in the previous generation, requests a transport reset,
        // then returns the old PCM. That PCM must never enter the fresh DSP state.
        let interrupted = try fixture.renderWithResetDuringInputPull(previous)
        #expect(interrupted.allSatisfy { channel in channel.allSatisfy { $0 == 0 } })

        let next = PitchEffectTestSignal.sine(frequency: 880, frames: 22_050)
        let actual = try fixture.render(next, trimLatency: false)
        let fresh = try PitchEffectRenderFixture(pitchCents: pitchCents)
        let expected = try fresh.render(next, trimLatency: false)

        // Keep the startup latency in the comparison: trimming it would hide
        // stale samples returned before the next track becomes audible.
        for channel in expected.indices {
            #expect(actual[channel].count == expected[channel].count)
            let maximumDifference = zip(actual[channel], expected[channel]).map { abs($0 - $1) }.max() ?? 0
            #expect(maximumDifference < 0.000_01)
        }
    }
}

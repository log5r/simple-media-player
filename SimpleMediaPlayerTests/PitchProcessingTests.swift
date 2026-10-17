import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct PitchProcessingTests {
    @Test(arguments: [48_000.0, 96_000.0], [AVAudioChannelCount(1), AVAudioChannelCount(2)])
    func loweredPitchKeepsHarmonicPeaksBelowFullScale(
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) throws {
        let source = try PitchProcessingSource(
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: PitchProcessingSource.harmonics(sampleRate: sampleRate)
        )
        defer { source.remove() }
        let encoder = PitchProcessingEncoder()
        let result = try render(source, encoder: encoder, pitchCents: -300, maxSampleRate: 48_000)

        #expect(encoder.sampleRate == 48_000)
        #expect(encoder.channels.count == Int(channelCount))
        #expect(encoder.frameCount == 48_000)
        #expect(abs(result.duration - 1) < 0.000_001)
        for samples in encoder.channels {
            #expect(samples.allSatisfy { $0.isFinite })
            #expect(samples.map { abs($0) }.max() ?? 0 <= 1)
            let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
            #expect(sqrt(meanSquare) > 0.02, "Peak protection must preserve the audible signal.")
        }
        #expect(encoder.finishCallCount == 1)
        #expect(encoder.cancelCallCount == 0)
    }

    @Test func sampleRateConversionCannotReintroduceClippingAfterPeakProtection() throws {
        var state: UInt32 = 0xCAFE_BABE
        let samples = (0..<48_000).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return state & 0x8000_0000 == 0 ? 0.88 : -0.88
        }
        let source = try PitchProcessingSource(sampleRate: 48_000, channelCount: 2, samples: samples)
        defer { source.remove() }
        let encoder = PitchProcessingEncoder()
        let result = try render(source, encoder: encoder, maxSampleRate: 44_100)

        #expect(encoder.sampleRate == 44_100)
        #expect(encoder.frameCount == 44_100)
        #expect(abs(result.duration - 1) < 0.000_001)
        for output in encoder.channels {
            #expect(output.allSatisfy { $0.isFinite })
            let peak = output.map { abs($0) }.max() ?? 0
            #expect(peak <= 1)
            #expect(peak > 0.5)
        }
        #expect(encoder.finishCallCount == 1)
        #expect(encoder.cancelCallCount == 0)
    }

    @Test func loweredPitchWAVExportRetainsItsDurationAndProtectedAudioAfterReopening() throws {
        let source = try PitchProcessingSource(
            sampleRate: 44_100, channelCount: 2,
            samples: PitchProcessingSource.harmonics(sampleRate: 44_100)
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitch-export-\(UUID().uuidString).wav")
        defer {
            source.remove()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let result = try TransformedAudioRenderer().render(
            sourceURL: source.url, pitchCents: -300, rate: 1, maxSampleRate: nil,
            makeEncoder: {
                try CoreAudioFileEncoder(outputURL: outputURL, format: .wav, processingFormat: $0)
            },
            progress: { _ in }
        )
        let reopened = try AVAudioFile(forReading: outputURL)
        #expect(reopened.length == 44_100)
        #expect(reopened.processingFormat.sampleRate == 44_100)
        #expect(reopened.processingFormat.channelCount == 2)
        #expect(abs(result.duration - 1) < 0.000_001)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reopened.processingFormat, frameCapacity: 44_100))
        try reopened.read(into: buffer)
        #expect(buffer.frameLength == 44_100)
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(reopened.processingFormat.channelCount) {
            let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
            #expect(samples.allSatisfy { $0.isFinite })
            let peak = samples.map { abs($0) }.max() ?? 0
            #expect(peak <= 1)
            // Integer PCM would hide over-range input by clipping it. The output
            // must retain headroom rather than merely become representable in WAV.
            #expect(peak < 0.999)
            let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
            #expect(sqrt(meanSquare) > 0.02)
        }
    }

    @Test(arguments: [64, 4_800])
    func limiterPreservesFirstAndLastImpulsesIncludingFilesShorterThanItsDelay(frameCount: Int) throws {
        var samples = [Float](repeating: 0, count: frameCount)
        samples[0] = 0.1
        samples[frameCount - 1] = -0.08
        let source = try PitchProcessingSource(sampleRate: 48_000, channelCount: 2, samples: samples)
        defer { source.remove() }
        let encoder = PitchProcessingEncoder()
        let result = try render(source, encoder: encoder)

        #expect(encoder.frameCount == frameCount)
        #expect(abs(result.duration - Double(frameCount) / 48_000) < 0.000_001)
        for (channel, output) in encoder.channels.enumerated() {
            try #require(output.count == frameCount)
            let channelGain: Float = channel == 0 ? 1 : -0.9
            #expect(abs(output[0] - 0.1 * channelGain) < 0.002)
            #expect(abs(output[frameCount - 1] + 0.08 * channelGain) < 0.002)
            #expect(output.dropFirst().dropLast().allSatisfy { abs($0) < 0.000_01 })
        }
        #expect(encoder.finishCallCount == 1)
    }

    @Test(arguments: [Float(0.5), Float(2)])
    func tempoChangeKeepsExpectedOutputDuration(rate: Float) throws {
        let source = try PitchProcessingSource(
            sampleRate: 48_000,
            channelCount: 1,
            samples: (0..<24_000).map { sin(Float($0) * 0.05) * 0.1 }
        )
        defer { source.remove() }
        let encoder = PitchProcessingEncoder()
        let result = try render(source, encoder: encoder, pitchCents: -300, rate: rate)

        let expectedFrames = Int((24_000 / Double(rate)).rounded(.up))
        #expect(encoder.frameCount == expectedFrames)
        #expect(abs(result.duration - Double(expectedFrames) / 48_000) < 0.000_001)
        #expect(encoder.finishCallCount == 1)
    }

    @Test(arguments: [PitchProcessingEncoder.Behavior.failEncoding, .cancelDuringEncoding])
    func pitchedRenderingCancelsEncoderAfterFailure(behavior: PitchProcessingEncoder.Behavior) async throws {
        let source = try PitchProcessingSource(
            sampleRate: 48_000,
            channelCount: 1,
            samples: [Float](repeating: 0.1, count: 4_800)
        )
        defer { source.remove() }
        let sourceURL = source.url
        let encoder = PitchProcessingEncoder(behavior: behavior)
        let task = Task.detached {
            try TransformedAudioRenderer().render(
                sourceURL: sourceURL,
                pitchCents: -300,
                rate: 1,
                maxSampleRate: nil,
                makeEncoder: { _ in encoder },
                progress: { _ in }
            )
        }

        let result = await task.result
        if case .failure(let error) = result {
            switch behavior {
            case .failEncoding:
                #expect(error is PitchProcessingEncoder.EncodingFailure)
            case .cancelDuringEncoding:
                #expect(error is CancellationError)
            case .record:
                Issue.record("The test must inject a failure or cancellation.")
            }
        } else {
            Issue.record("Rendering unexpectedly succeeded after encoding was interrupted.")
        }
        #expect(encoder.finishCallCount == 0)
        #expect(encoder.cancelCallCount == 1)
    }

    private func render(
        _ source: PitchProcessingSource,
        encoder: PitchProcessingEncoder,
        pitchCents: Float = 0,
        rate: Float = 1,
        maxSampleRate: Double? = nil
    ) throws -> TransformedAudioRenderer.Result {
        try TransformedAudioRenderer().render(
            sourceURL: source.url,
            pitchCents: pitchCents,
            rate: rate,
            maxSampleRate: maxSampleRate,
            makeEncoder: { _ in encoder },
            progress: { _ in }
        )
    }
}

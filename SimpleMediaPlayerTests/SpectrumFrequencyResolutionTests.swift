import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct SpectrumFrequencyResolutionTests {
    @Test(arguments: VisualizerResponseMode.allCases, [44_100.0, 48_000.0, 192_000.0])
    func smallVideoBuffersResolveIndependentLowFrequencyBands(
        mode: VisualizerResponseMode, sampleRate: Double
    ) async throws {
        // Keep tones away from band boundaries, where the Hann main lobe
        // legitimately reaches a neighboring band and smoothing can favor it.
        for (leftFrequency, rightFrequency) in [(27.0, 55.0), (55.0, 90.0), (90.0, 27.0)] {
            let frame = try await analyzedFrame(
                leftFrequency: leftFrequency, rightFrequency: rightFrequency,
                mode: mode, sampleRate: sampleRate
            )
            expectDominantBand(frame.bandsL, frequency: leftFrequency)
            expectDominantBand(frame.bandsR, frequency: rightFrequency)
        }
    }

    @Test(arguments: VisualizerResponseMode.allCases)
    func contiguousSourceRangesPreserveLowFrequencyHistory(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let generation = analyzer.realtimeVideoGeneration
        let chunkFrames = Int(48_000 / mode.framesPerSecond)
        var sourceTime = 0.0
        for index in 0..<8 {
            let range = (index * 4_096)..<((index + 1) * 4_096)
            let sourceEndTime = sourceTime + (index.isMultiple(of: 2) ? 0.081375 : 0.093)
            var batch = VideoAudioSampleRing.Batch(
                left: tone(frequency: 27, sampleRate: 48_000, range: range),
                right: tone(frequency: 55, sampleRate: 48_000, range: range),
                sampleRate: 48_000, time: sourceTime, analysisGeneration: generation,
                sourceEpoch: 3, startsStream: index == 0
            )
            batch.sourceEndTime = sourceEndTime
            analyzer.analyzeVideoSamples(batch) { true }
            let expectedFrames = (index + 1) * 4_096 / chunkFrames
            try await waitUntil { frames.count == expectedFrames }
            sourceTime = sourceEndTime
        }
        let frame = try #require(frames.last)
        expectDominantBand(frame.bandsL, frequency: 27)
        expectDominantBand(frame.bandsR, frequency: 55)
    }

    @Test func shortFFTDoesNotCopyOneBinIntoEmptyLowFrequencyBands() {
        let samples = tone(frequency: 46.875, sampleRate: 48_000, range: 0..<1_024)
        let levels = SpectrumFFT().bandLevels(for: samples, sampleRate: 48_000, bandCount: 16)

        // The first non-DC bin is 46.875 Hz. Only the 30.8–47.4 Hz band owns it;
        // the bands on either side contain no FFT bins at this window length.
        #expect(levels[0] == 0)
        #expect(levels[2] == 0)
        #expect(levels[1] > 0.5)
    }

    @Test func nonPowerOfTwoInputUsesTheMostRecentSamples() {
        let fft = SpectrumFFT()
        let oldSamples = tone(frequency: 440, sampleRate: 48_000, range: 0..<512)
        let latestSamples = tone(frequency: 3_000, sampleRate: 48_000, range: 512..<1_536)
        let expected = fft.bandLevels(for: latestSamples, sampleRate: 48_000, bandCount: 16)
        let actual = fft.bandLevels(for: oldSamples + latestSamples, sampleRate: 48_000, bandCount: 16)

        for (actualLevel, expectedLevel) in zip(actual, expected) {
            #expect(abs(actualLevel - expectedLevel) < 0.000_001)
        }
    }

    private func analyzedFrame(
        leftFrequency: Double, rightFrequency: Double,
        mode: VisualizerResponseMode, sampleRate: Double
    ) async throws -> AudioFrameData {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let generation = analyzer.realtimeVideoGeneration
        let sampleCount = Int(sampleRate * 0.6)
        let bufferSize = sampleRate <= 48_000 ? 512 : 1_024
        let chunkFrames = Int(sampleRate / mode.framesPerSecond)
        for offset in stride(from: 0, to: sampleCount, by: bufferSize) {
            let range = offset..<min(offset + bufferSize, sampleCount)
            analyzer.analyzeVideoSamples(.init(
                left: tone(frequency: leftFrequency, sampleRate: sampleRate, range: range),
                right: tone(frequency: rightFrequency, sampleRate: sampleRate, range: range),
                sampleRate: sampleRate, time: Double(offset) / sampleRate,
                analysisGeneration: generation, sourceEpoch: 3, startsStream: offset == 0
            )) { true }
        }
        let expectedFrames = sampleCount / chunkFrames
        try await waitUntil { frames.count == expectedFrames }
        return try #require(frames.last)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func expectDominantBand(_ levels: [Float], frequency: Double) {
        let band = Int(floor(log(frequency / 20) / log(1_000) * 16))
        let otherPeak = levels.enumerated().filter { $0.offset != band }.map(\.element).max() ?? 0
        #expect(levels[band] > otherPeak + 0.01, "\(frequency) Hz should dominate band \(band): \(levels)")
    }

    private func tone(frequency: Double, sampleRate: Double, range: Range<Int>) -> [Float] {
        range.map { Float(sin(Double($0) * 2 * .pi * frequency / sampleRate)) * 0.08 }
    }
}

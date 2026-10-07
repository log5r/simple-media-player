import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct VideoSpectrumAnalysisTests {
    @Test(arguments: VisualizerResponseMode.allCases, [512, 1_024, 4_800])
    func tapBufferSizeDoesNotChangeEmissionRate(mode: VisualizerResponseMode, bufferSize: Int) async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let sampleRate = 48_000.0
        let generation = analyzer.realtimeVideoGeneration
        var offset = 0
        while offset < 48_000 {
            let count = min(bufferSize, 48_000 - offset)
            let samples = (offset..<(offset + count)).map {
                Float(sin(Double($0) * 2 * .pi * 440 / sampleRate)) * 0.4
            }
            analyzer.analyzeVideoSamples(.init(
                left: samples, right: samples.map { $0 * 0.5 }, sampleRate: sampleRate,
                time: Double(offset) / sampleRate, analysisGeneration: generation,
                sourceEpoch: 3, startsStream: offset == 0
            )) { true }
            offset += count
        }
        try await waitUntil { frames.count == Int(mode.framesPerSecond) }
        #expect(frames.allSatisfy { $0.isPlaying && !$0.isSilent && $0.rmsL > $0.rmsR })
        let times = frames.map(\.currentTime).sorted()
        for (index, time) in times.enumerated() {
            #expect(abs(time - Double(index) / mode.framesPerSecond) < 0.000_001)
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.count == Int(mode.framesPerSecond))
    }

    @Test func sourceInvalidationRejectsDelayedChunksEvenWhenAnalyzerStillPlays() async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setPlaybackActive(true, currentTime: 0)
        let state = VideoAudioTapState()
        let epoch = state.setActive(true)
        let samples = Array(repeating: Float(0.4), count: 48_000)
        analyzer.analyzeVideoSamples(.init(
            left: samples, right: samples, sampleRate: 48_000,
            time: 0, analysisGeneration: analyzer.realtimeVideoGeneration,
            sourceEpoch: epoch, startsStream: true
        )) { state.epoch.load(ordering: .acquiring) == epoch }
        try await waitUntil { !frames.isEmpty }
        state.setActive(false)
        state.setActive(true)
        let count = frames.count
        try await Task.sleep(for: .milliseconds(250))
        #expect(frames.count == count)
    }

    @Test func seekDiscardsPartialSamplesAndInactiveGenerationIsZero() async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        #expect(analyzer.realtimeVideoGeneration == 0)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let oldGeneration = analyzer.realtimeVideoGeneration
        let partial = Array(repeating: Float(0.5), count: 1_024)
        analyzer.analyzeVideoSamples(.init(
            left: partial, right: partial, sampleRate: 48_000,
            time: 0, analysisGeneration: oldGeneration, sourceEpoch: 3, startsStream: true
        )) { true }
        analyzer.setPlaybackActive(true, currentTime: 20)
        let samples = Array(repeating: Float(0.25), count: 1_600)
        analyzer.analyzeVideoSamples(.init(
            left: samples, right: samples, sampleRate: 48_000,
            time: 20, analysisGeneration: analyzer.realtimeVideoGeneration,
            sourceEpoch: 5, startsStream: true
        )) { true }
        try await waitUntil { !frames.isEmpty }
        #expect(frames.allSatisfy { $0.currentTime == 20 })
        analyzer.setPlaybackActive(false, currentTime: 20)
        #expect(analyzer.realtimeVideoGeneration == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

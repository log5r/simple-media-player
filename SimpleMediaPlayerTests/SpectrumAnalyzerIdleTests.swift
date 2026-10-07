import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct SpectrumAnalyzerIdleTests {
    @Test func pausedBuffersDoNotProduceAnalysisFrames() async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        let buffer = try toneBuffer()
        // Even a loud tail delivered by a still-running engine must skip analysis.
        analyzer.setPlaybackActive(true, currentTime: 0)
        for _ in 0..<500 {
            analyzer.analyze(buffer, currentTime: 5, isPlaying: false)
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.isEmpty)
    }

    @Test(arguments: VisualizerResponseMode.allCases)
    func stoppingDecaysToExactSilenceThenStopsPublishing(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let buffer = try toneBuffer()
        analyzer.analyze(buffer, currentTime: 1, isPlaying: true)
        try await waitUntil { frames.contains { $0.isPlaying && $0.isSilent == false } }
        analyzer.setPlaybackActive(false, currentTime: 2)
        try await waitUntil {
            frames.last.map { $0.isPlaying == false && $0.isSilent } == true
        }
        #expect(frames.contains { $0.isPlaying == false && $0.isSilent == false })
        #expect(frames.last?.currentTime == 2)
        let count = frames.count

        // Both late playing callbacks and paused engine taps are ignored after suspension.
        analyzer.analyze(buffer, currentTime: 99, isPlaying: true)
        analyzer.analyze(buffer, currentTime: 99, isPlaying: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(frames.count == count)
    }

    @Test(arguments: [VisualizerResponseMode.normal, .fast])
    func stoppingAndResumingDiscardOldChunksAndDecayCallbacks(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        // One second of input schedules chunks that will arrive after the stop and resume.
        analyzer.analyze(try toneBuffer(frameCount: 44_100), currentTime: 1, isPlaying: true)
        try await waitUntil { frames.contains { $0.isPlaying } }
        analyzer.setPlaybackActive(false, currentTime: 2)
        let stoppedAt = frames.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(frames.dropFirst(stoppedAt).allSatisfy { $0.isPlaying == false && $0.currentTime == 2 })

        analyzer.setPlaybackActive(true, currentTime: 20)
        let resumedAt = frames.count
        analyzer.analyze(try toneBuffer(), currentTime: 20, isPlaying: true)
        try await waitUntil { frames.last.map { $0.isPlaying && $0.currentTime >= 20 } == true }
        try await Task.sleep(for: .milliseconds(250))
        #expect(frames.dropFirst(resumedAt).allSatisfy { $0.isPlaying && $0.currentTime >= 20 })
    }

    @Test(arguments: VisualizerResponseMode.allCases)
    func resumedSilentAudioDoesNotInheritPreviousPeaks(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let buffer = try toneBuffer()
        analyzer.analyze(buffer, currentTime: 1, isPlaying: true)
        try await waitUntil { frames.contains { $0.isPlaying && !$0.isSilent } }
        analyzer.setPlaybackActive(false, currentTime: 2)
        analyzer.setPlaybackActive(true, currentTime: 20)
        let resumedAt = frames.count
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(buffer.format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
        analyzer.analyze(buffer, currentTime: 20, isPlaying: true)
        try await waitUntil { frames.count > resumedAt }
        #expect(frames.dropFirst(resumedAt).allSatisfy { $0.isPlaying && $0.isSilent && $0.currentTime >= 20 })
    }

    @Test func changingBandCountWhileIdlePublishesOnlyTheNewLayout() async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setBandCount(32)
        try await waitUntil { frames.last?.bandsL.count == 32 }
        #expect(frames.last?.isSilent == true)
        #expect(frames.last?.isPlaying == false)
        let count = frames.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.count == count)
    }

    @Test func silenceIncludesHeldPeaksAndBothChannels() {
        var frame = AudioFrameData.silent()
        #expect(frame.isSilent)
        frame.peakRmsR = 0.1
        #expect(frame.isSilent == false)
        frame.peakRmsR = 0
        frame.peaksL[0] = 0.1
        #expect(frame.isSilent == false)
        frame.peaksL[0] = 0
        frame.bandsR[0] = 0.1
        #expect(frame.isSilent == false)
    }

    private func toneBuffer(frameCount: AVAudioFrameCount = 4_410) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<Int(frameCount) {
            let sample = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.4
            channels[0][index] = sample
            channels[1][index] = sample * 0.5
        }
        return buffer
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while condition() == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

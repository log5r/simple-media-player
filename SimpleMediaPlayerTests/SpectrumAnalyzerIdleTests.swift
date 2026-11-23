import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct SpectrumAnalyzerIdleTests {
    @Test(arguments: [AVAudioChannelCount(1), 2])
    func audioTapPreservesStereoChannelsAndMirrorsMono(channelCount: AVAudioChannelCount) async throws {
        let analyzer = SpectrumAnalyzer()
        let tap = TestSpectrumAudioTap(analyzer)
        var frame: AudioFrameData?
        analyzer.onFrame = { frame = $0 }
        analyzer.setResponseMode(.slow)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let buffer = try toneBuffer(channelCount: channelCount)
        tap.submit(AVReadOnlyAudioPCMBuffer(copying: buffer), currentTime: 1, isPlaying: true)

        try await waitUntil { frame != nil }
        let result = try #require(frame)
        #expect(result.rmsL > 0)
        #expect(result.bandsL.contains { $0 > 0 })
        if channelCount == 1 {
            #expect(result.rmsR == result.rmsL)
            #expect(result.bandsR == result.bandsL)
        } else {
            #expect(result.rmsR > 0 && result.rmsR < result.rmsL)
            let leftPeak = try #require(result.bandsL.indices.max { result.bandsL[$0] < result.bandsL[$1] })
            let rightPeak = try #require(result.bandsR.indices.max { result.bandsR[$0] < result.bandsR[$1] })
            #expect(leftPeak < rightPeak)
        }
    }

    @Test func pausedBuffersDoNotProduceAnalysisFrames() async throws {
        let analyzer = SpectrumAnalyzer()
        let tap = TestSpectrumAudioTap(analyzer)
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        let buffer = try toneBuffer()
        // Even a loud tail delivered by a still-running engine must skip analysis.
        analyzer.setPlaybackActive(true, currentTime: 0)
        for _ in 0..<500 {
            tap.submit(AVReadOnlyAudioPCMBuffer(copying: buffer), currentTime: 5, isPlaying: false)
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.isEmpty)
    }

    @Test(arguments: VisualizerResponseMode.allCases)
    func stoppingDecaysToExactSilenceThenStopsPublishing(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        let tap = TestSpectrumAudioTap(analyzer)
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let buffer = try toneBuffer()
        tap.submit(AVReadOnlyAudioPCMBuffer(copying: buffer), currentTime: 1, isPlaying: true)
        try await waitUntil { frames.contains { $0.isPlaying && $0.isSilent == false } }
        analyzer.setPlaybackActive(false, currentTime: 2)
        try await waitUntil {
            frames.last.map { $0.isPlaying == false && $0.isSilent } == true
        }
        #expect(frames.contains { $0.isPlaying == false && $0.isSilent == false })
        #expect(frames.last?.currentTime == 2)
        let count = frames.count

        // Both late playing callbacks and paused engine taps are ignored after suspension.
        tap.submit(AVReadOnlyAudioPCMBuffer(copying: buffer), currentTime: 99, isPlaying: true)
        tap.submit(AVReadOnlyAudioPCMBuffer(copying: buffer), currentTime: 99, isPlaying: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(frames.count == count)
    }

    @Test(arguments: [VisualizerResponseMode.normal, .fast])
    func stoppingAndResumingDiscardOldChunksAndDecayCallbacks(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        let tap = TestSpectrumAudioTap(analyzer)
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        // One second of input schedules chunks that will arrive after the stop and resume.
        tap.submit(
            AVReadOnlyAudioPCMBuffer(copying: try toneBuffer(frameCount: 44_100)), currentTime: 1, isPlaying: true
        )
        try await waitUntil { frames.contains { $0.isPlaying } }
        analyzer.setPlaybackActive(false, currentTime: 2)
        let stoppedAt = frames.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(frames.dropFirst(stoppedAt).allSatisfy { $0.isPlaying == false && $0.currentTime == 2 })

        analyzer.setPlaybackActive(true, currentTime: 20)
        let resumedAt = frames.count
        tap.submit(AVReadOnlyAudioPCMBuffer(copying: try toneBuffer()), currentTime: 20, isPlaying: true)
        try await waitUntil { frames.last.map { $0.isPlaying && $0.currentTime >= 20 } == true }
        try await Task.sleep(for: .milliseconds(250))
        #expect(frames.dropFirst(resumedAt).allSatisfy { $0.isPlaying && $0.currentTime >= 20 })
    }

    @Test(arguments: VisualizerResponseMode.allCases)
    func resumedSilentAudioDoesNotInheritPreviousPeaks(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        let tap = TestSpectrumAudioTap(analyzer)
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let buffer = try toneBuffer()
        tap.submit(AVReadOnlyAudioPCMBuffer(copying: buffer), currentTime: 1, isPlaying: true)
        try await waitUntil { frames.contains { $0.isPlaying && !$0.isSilent } }
        analyzer.setPlaybackActive(false, currentTime: 2)
        analyzer.setPlaybackActive(true, currentTime: 20)
        let resumedAt = frames.count
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(buffer.format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
        tap.submit(AVReadOnlyAudioPCMBuffer(copying: buffer), currentTime: 20, isPlaying: true)
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

    private func toneBuffer(
        frameCount: AVAudioFrameCount = 4_410, channelCount: AVAudioChannelCount = 2
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: channelCount))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<Int(frameCount) {
            let phase = Double(index) * 2 * .pi / 44_100
            channels[0][index] = Float(sin(phase * 440)) * 0.4
            if channelCount > 1 { channels[1][index] = Float(sin(phase * 2_000)) * 0.2 }
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

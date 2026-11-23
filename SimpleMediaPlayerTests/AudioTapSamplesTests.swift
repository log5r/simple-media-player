import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct AudioTapSamplesTests {
    @Test func rejectedBufferLeavesSlotAvailableAndReusedSlotPreservesPreviousChunk() throws {
        let samples = AudioTapSamples(capacity: 512)
        let oversized = try buffer(value: 1, frameCount: 513)
        let full = try buffer(value: 0.5)
        let short = try buffer(value: 0, frameCount: 64)
        #expect(!samples.copyIfAvailable(oversized, generation: 1))
        try #require(samples.copyIfAvailable(full, generation: 1))
        let (firstLeft, firstRight) = samples.channels(in: 0..<samples.frameCount)
        samples.release()

        try #require(samples.copyIfAvailable(short, generation: 2))
        let (nextLeft, nextRight) = samples.channels(in: 0..<samples.frameCount)
        samples.release()
        #expect(firstLeft == Array(repeating: 0.5, count: 512))
        #expect(firstRight == firstLeft)
        #expect(nextLeft == Array(repeating: 0, count: 64))
        #expect(nextRight == nextLeft)
    }

    @Test func busyAnalyzerDropsNewPCMWithoutWaitingOrOverwritingPendingSamples() async throws {
        let queue = DispatchQueue(label: "AudioTapSamplesTests.analysis")
        let analyzer = SpectrumAnalyzer(queue: queue)
        let tap = TestSpectrumAudioTap(analyzer)
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(.slow)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let loud = try buffer(value: 0.5)
        let silence = try buffer(value: 0)
        let producer = DispatchQueue(label: "AudioTapSamplesTests.producer")
        let returned = DispatchSemaphore(value: 0)

        queue.suspend()
        do {
            defer { queue.resume() }
            producer.async {
                tap.submit(loud, currentTime: 1)
                returned.signal()
            }
            try #require(await returned.waitAsync(timeout: .now() + 4) == .success)
            // The rate limit has elapsed, but the first buffer still owns the slot.
            try await Task.sleep(for: .milliseconds(40))
            producer.async {
                tap.submit(silence, currentTime: 2)
                returned.signal()
            }
            try #require(await returned.waitAsync(timeout: .now() + 4) == .success)
        }

        try await waitUntil { !frames.isEmpty }
        #expect(frames.first?.currentTime == 1)
        #expect(frames.first?.isSilent == false)
        await queue.drain()
        tap.submit(silence, currentTime: 3)
        try await waitUntil { frames.last?.currentTime == 3 }
        #expect(frames.map(\.currentTime) == [1, 3])
    }

    @Test func seekRejectsQueuedSamplesAndCallbacksCapturedBeforeTheSeek() async throws {
        let queue = DispatchQueue(label: "AudioTapSamplesTests.seek")
        let analyzer = SpectrumAnalyzer(queue: queue)
        let tap = TestSpectrumAudioTap(analyzer)
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(.slow)
        analyzer.setPlaybackActive(true, currentTime: 0)
        let loud = try buffer(value: 0.5)
        let silence = try buffer(value: 0)
        let captured = analyzer.realtimeAnalysisGeneration

        queue.suspend()
        tap.submit(loud, currentTime: 1)
        analyzer.setPlaybackActive(true, currentTime: 20)
        queue.resume()
        await queue.drain()

        // This callback had already sampled the old clock before the seek completed.
        tap.submit(loud, currentTime: 2, generation: captured)
        await queue.drain()
        try await Task.sleep(for: .milliseconds(40))
        tap.submit(silence, currentTime: 20)
        try await waitUntil { frames.last?.currentTime == 20 }
        #expect(frames.count == 1)
        #expect(frames.last?.isSilent == true)
    }

    private func buffer(value: Float, frameCount: AVAudioFrameCount = 512) throws -> AVReadOnlyAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?[0])
        channel.update(repeating: value, count: Int(buffer.frameLength))
        return AVReadOnlyAudioPCMBuffer(copying: buffer)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

// Each simulated tap owns one buffer, including tests with a full second of PCM.
nonisolated struct TestSpectrumAudioTap: Sendable {
    private let analyzer: SpectrumAnalyzer
    private let samples = AudioTapSamples(capacity: 44_100)

    init(_ analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    func submit(
        _ buffer: AVReadOnlyAudioPCMBuffer, currentTime: TimeInterval,
        isPlaying: Bool = true, generation: Int? = nil
    ) {
        analyzer.analyze(
            buffer, using: samples, currentTime: currentTime,
            generation: isPlaying ? (generation ?? analyzer.realtimeAnalysisGeneration) : 0
        )
    }
}

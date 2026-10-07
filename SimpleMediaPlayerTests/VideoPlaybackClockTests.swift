import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct VideoPlaybackClockTests {
    @Test func unloadedPlayerHasZeroTime() {
        let service = VideoPlayerService(analyzer: SpectrumAnalyzer())
        #expect(service.currentTime == 0)
    }

    @Test func nativePlayerClockAdvancesBetweenHalfSecondBoundaries() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let service = VideoPlayerService(analyzer: SpectrumAnalyzer())
        service.setVolume(0)
        await service.load(url: url)
        defer { service.close() }
        service.play()
        // Allow AVPlayer to prepare its timebase before measuring its clock.
        for _ in 0..<100 {
            if service.player.currentTime().seconds > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.player.currentTime().seconds > 0)
        var positions = Set<Int>()
        for _ in 0..<8 {
            let nativeTime = service.player.currentTime().seconds
            #expect(abs(service.currentTime - nativeTime) < 0.03)
            positions.insert(Int(service.currentTime * 100))
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(positions.count >= 3)
        service.pause()
        let pausedTime = service.currentTime
        try await Task.sleep(for: .milliseconds(80))
        #expect(abs(service.currentTime - pausedTime) < 0.03)
    }

    @Test func nativeTapProducesMetersAndRejectsSamplesAfterTransportChanges() async throws {
        let url = try await makeSilentAudio(withTone: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        let service = VideoPlayerService(analyzer: analyzer)
        service.setVolume(0)
        await service.load(url: url)
        defer { service.close() }
        analyzer.setPlaybackActive(true, currentTime: 0)
        service.play()
        try await waitUntil { frames.contains { $0.isPlaying && !$0.isSilent } }
        #expect(frames.last?.rmsL == frames.last?.rmsR) // Mono feeds both meter channels.

        service.pause()
        analyzer.setPlaybackActive(false, currentTime: service.currentTime)
        let pausedAt = frames.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.dropFirst(pausedAt).allSatisfy { !$0.isPlaying })

        service.play()
        analyzer.setPlaybackActive(true, currentTime: service.currentTime)
        let resumedAt = frames.count
        try await waitUntil { frames.dropFirst(resumedAt).contains { $0.isPlaying } }
        service.seek(to: 1)
        service.pause()
        service.play() // Resume while the first seek completion is still pending.
        service.seek(to: 2) // The superseded completion must not reactivate stale samples.
        analyzer.setPlaybackActive(true, currentTime: 2)
        let soughtAt = frames.count
        try await waitUntil { frames.dropFirst(soughtAt).contains { $0.isPlaying && $0.currentTime >= 2 } }
        #expect(frames.dropFirst(soughtAt).allSatisfy { $0.currentTime >= 2 })

        service.stop()
        analyzer.setPlaybackActive(false, currentTime: 0)
        let stoppedAt = frames.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.dropFirst(stoppedAt).allSatisfy { !$0.isPlaying })
        service.close()
        analyzer.setPlaybackActive(true, currentTime: 100)
        let closedAt = frames.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.count == closedAt)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

    private func makeSilentAudio(withTone: Bool = false) async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-clock-\(UUID().uuidString).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][frame] = withTone
                    ? Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.4 : 0
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<5 { try file.write(from: buffer) }
            return url
        }.value
    }
}

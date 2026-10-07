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

    private func makeSilentAudio() async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-clock-\(UUID().uuidString).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<5 { try file.write(from: buffer) }
            return url
        }.value
    }
}

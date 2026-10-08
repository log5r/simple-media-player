import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.serialized)
struct AudioEngineFinishNotificationTests {
    @Test func finishQueuedBeforeNextLoadIsNotDeliveredForSelectedTrack() async throws {
        let first = try await makeSilentAudio()
        let second = try await makeSilentAudio()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let probe = try await makeEngineAtEnd(of: first)
        defer { probe.engine.suspend() }

        // 終端処理を制御キューへ積んだ直後、その MainActor 通知より先に次の曲を読み込む
        probe.engine.play()
        probe.engine.load(url: second)
        try await waitUntil { probe.loadedDurations.count == 2 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(probe.finishedCount == 0)
    }

    @Test func finishWithoutTrackChangeIsDelivered() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)
        defer { probe.engine.suspend() }

        probe.engine.play()
        try await waitUntil { probe.finishedCount == 1 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(probe.finishedCount == 1)
    }

    @Test func finishQueuedBeforeSeekBackIsNotDelivered() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)
        defer { probe.engine.suspend() }

        probe.engine.play()
        probe.engine.seek(to: 0, autoPlay: false)
        try await Task.sleep(for: .milliseconds(200))

        #expect(probe.finishedCount == 0)
    }

    @Test func finishQueuedBeforePauseAndResumeIsDeliveredOnlyForResumedPlayback() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)
        defer { probe.engine.suspend() }

        // 再開後の再生も終端から始まるため、通知は再開した再生の 1 回だけになる
        probe.engine.play()
        probe.engine.pause()
        probe.engine.play()
        try await waitUntil { probe.finishedCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))

        #expect(probe.finishedCount == 1)
    }

    @Test func finishQueuedBeforeSuspendIsNotDelivered() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)

        probe.engine.play()
        probe.engine.suspend()
        try await Task.sleep(for: .milliseconds(200))

        #expect(probe.finishedCount == 0)
    }

    // 終端へシークしておくと、次の play() が制御キュー上で即座に終端処理を行う
    private func makeEngineAtEnd(of url: URL) async throws -> FinishProbe {
        let probe = FinishProbe(engine: AudioEngineService(analyzer: SpectrumAnalyzer()))
        probe.engine.setVolume(0)
        probe.engine.load(url: url)
        try await waitUntil { probe.loadedDurations.count == 1 }
        let duration = try #require(probe.loadedDurations.first)
        probe.engine.seek(to: duration + 1, autoPlay: false)
        try await waitUntil { probe.engine.currentTime >= duration }
        return probe
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func makeSilentAudio() async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("finish-notification-\(UUID().uuidString).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
            buffer.frameLength = buffer.frameCapacity
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }.value
    }
}

@MainActor
private final class FinishProbe {
    let engine: AudioEngineService
    var loadedDurations: [TimeInterval] = []
    var finishedCount = 0

    init(engine: AudioEngineService) {
        self.engine = engine
        engine.onFormatLoaded = { [weak self] duration, _ in self?.loadedDurations.append(duration) }
        engine.onFinished = { [weak self] in self?.finishedCount += 1 }
    }
}

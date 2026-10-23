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

        try await probe.enqueueFinish()
        probe.engine.load(url: second)
        try await probe.waitForLoad()
        probe.notifications.deliverNext()
        #expect(probe.finishedCount == 0)
        #expect(probe.loadedDurations.count == 2)
        #expect(probe.engine.currentTime == 0)
    }

    @Test func finishWithoutTrackChangeIsDelivered() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)
        defer { probe.engine.suspend() }

        try await probe.enqueueFinish()
        probe.notifications.deliverNext()
        #expect(probe.finishedCount == 1)
        #expect(probe.notifications.pendingCount == 0)
    }

    @Test func finishQueuedBeforeSeekBackIsNotDelivered() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)
        defer { probe.engine.suspend() }

        try await probe.enqueueFinish()
        probe.engine.seek(to: 0, autoPlay: false)
        _ = await probe.engine.isEngineRunning
        probe.notifications.deliverNext()
        #expect(probe.finishedCount == 0)
        #expect(probe.engine.currentTime == 0)
    }

    @Test func finishQueuedBeforePauseAndResumeIsDeliveredOnlyForResumedPlayback() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)
        defer { probe.engine.suspend() }

        try await probe.enqueueFinish()
        probe.engine.pause()
        try await probe.enqueueFinish()
        #expect(probe.notifications.pendingCount == 2)
        probe.notifications.deliverNext()
        #expect(probe.finishedCount == 0)
        probe.notifications.deliverNext()
        #expect(probe.finishedCount == 1)
    }

    @Test(arguments: [false, true])
    func finishQueuedBeforeStopIsNotDelivered(reset: Bool) async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)
        defer { probe.engine.suspend() }
        let endTime = probe.engine.currentTime

        try await probe.enqueueFinish()
        probe.engine.stop(reset: reset)
        _ = await probe.engine.isEngineRunning
        probe.notifications.deliverNext()
        #expect(probe.finishedCount == 0)
        #expect(probe.engine.currentTime == (reset ? 0 : endTime))
    }

    @Test func finishQueuedBeforeSuspendIsNotDelivered() async throws {
        let url = try await makeSilentAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try await makeEngineAtEnd(of: url)

        try await probe.enqueueFinish()
        probe.engine.suspend()
        #expect(await probe.engine.isEngineRunning == false)
        probe.notifications.deliverNext()
        #expect(probe.finishedCount == 0)
        #expect(probe.engine.currentTime == 0)
    }

    private func makeEngineAtEnd(of url: URL) async throws -> FinishProbe {
        let probe = FinishProbe()
        probe.engine.setVolume(0)
        probe.engine.load(url: url)
        try await probe.waitForLoad()
        let duration = try #require(probe.loadedDurations.first)
        probe.engine.seek(to: duration + 1, autoPlay: false)
        _ = await probe.engine.isEngineRunning
        try #require(probe.engine.currentTime >= duration)
        return probe
    }

    private func makeSilentAudio() async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("finish-notification-\(UUID().uuidString).wav")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            samples.initialize(repeating: 0, count: Int(buffer.frameLength))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }.value
    }
}

@MainActor
private final class FinishProbe {
    let engine: AudioEngineService
    let notifications: HeldFinishNotifications
    private let loaded = DispatchSemaphore(value: 0)
    var loadedDurations: [TimeInterval] = []
    var finishedCount = 0

    init() {
        let notifications = HeldFinishNotifications()
        self.notifications = notifications
        engine = AudioEngineService(
            analyzer: SpectrumAnalyzer(), deliverFinishNotification: { notifications.enqueue($0) }
        )
        engine.onFormatLoaded = { [weak self] duration, _ in
            self?.loadedDurations.append(duration)
            self?.loaded.signal()
        }
        engine.onFinished = { [weak self] in self?.finishedCount += 1 }
    }

    func waitForLoad() async throws {
        try #require(await loaded.waitAsync(timeout: .now() + 5) == .success)
    }

    func enqueueFinish() async throws {
        engine.play()
        // The old notification exists before another transport action is allowed.
        // Awaiting the control queue alone would let MainActor deliver it too early.
        try #require(await notifications.enqueued.waitAsync(timeout: .now() + 5) == .success)
    }
}

nonisolated private final class HeldFinishNotifications: @unchecked Sendable {
    let enqueued = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pending: [@MainActor @Sendable () -> Void] = []

    var pendingCount: Int { lock.withLock { pending.count } }

    func enqueue(_ notification: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { pending.append(notification) }
        enqueued.signal()
    }

    @MainActor func deliverNext() {
        let notification = lock.withLock { pending.removeFirst() }
        notification()
    }
}

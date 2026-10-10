import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

private let blockingWorkQueueLabel = "SimpleMediaPlayer.BlockingWork"

nonisolated private func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

struct BlockingWorkExecutorTests {
    @Test func blockedWorkLeavesTheCooperativePoolFree() async throws {
        // On the cooperative pool, more blocked tasks than it has threads could not all start.
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let tasks = (0..<count).map { _ in
            Task.detached(executorPreference: BlockingWorkExecutor.shared) { () -> Bool in
                started.signal()
                return gate.wait(timeout: .now() + 10) == .success
            }
        }
        var results: [DispatchTimeoutResult] = []
        for _ in 0..<count { results.append(await started.waitAsync(timeout: .now() + 5)) }
        #expect(results.allSatisfy { $0 == .success })

        let cooperative = DispatchSemaphore(value: 0)
        Task.detached { cooperative.signal() }
        #expect(await cooperative.waitAsync(timeout: .now() + 2) == .success)

        for _ in 0..<count { gate.signal() }
        for task in tasks { #expect(await task.value) }
    }

    @Test func blockingWorkRunsOnItsQueueAndObservesCancellation() async throws {
        let started = DispatchSemaphore(value: 0)
        let task = Task.detached(executorPreference: BlockingWorkExecutor.shared) { () -> (String, Bool) in
            let label = currentQueueLabel()
            started.signal()
            let deadline = Date().addingTimeInterval(5)
            while Task.isCancelled == false, Date() < deadline { usleep(1_000) }
            return (label, Task.isCancelled)
        }
        try #require(await started.waitAsync(timeout: .now() + 5) == .success)
        task.cancel()
        let (label, observedCancellation) = await task.value
        #expect(label == blockingWorkQueueLabel)
        #expect(observedCancellation)
    }

    @Test func musicAnalysisOpensTheSourceOnTheBlockingQueue() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let labels = LabelRecorder()
        let service = MusicAnalysisService(cacheDirectory: nil, readableFile: { _ in
            labels.record()
            throw CocoaError(.fileReadUnknown)
        }, waitBeforeAnalyzing: {})
        await #expect(throws: CocoaError.self) {
            try await service.analyze(url: URL(fileURLWithPath: "/track-switch-tests/missing.ape"))
        }
        #expect(labels.values == [blockingWorkQueueLabel])
    }
}

@MainActor
@Suite(.serialized)
struct AudioEngineTrackSwitchTests {
    @Test func nextTrackOpensWhilePreviousTrackFadesOut() async throws {
        let first = try makeSilentAudio(seconds: 5)
        let second = try makeSilentAudio(seconds: 1)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let preparation = PreparationProbe(next: second)
        let probe = LoadProbe(engine: AudioEngineService(
            analyzer: SpectrumAnalyzer(),
            openReadableFile: { try preparation.open($0) },
            waitForFadeStep: { _ in preparation.fadeStep() }
        ))
        defer { probe.engine.suspend() }

        probe.engine.load(url: first)
        try await waitUntil { probe.loadedDurations.count == 1 }
        // The control queue starts playback before it handles the next load, which then fades out.
        probe.engine.play()
        probe.engine.load(url: second)
        try await waitUntil { probe.loadedDurations.count == 2 }

        #expect(probe.errors.isEmpty)
        try #require(preparation.fadeStepCount > 0, "The first track must be playing so that switching fades it out")
        #expect(preparation.openedBeforeFadeEnded == true)
        #expect(abs((probe.loadedDurations.last ?? 0) - 1) < 0.01)
        #expect(probe.engine.duration == probe.loadedDurations.last)
        #expect(preparation.queueLabels == [blockingWorkQueueLabel, blockingWorkQueueLabel])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func makeSilentAudio(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-switch-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frameCount = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

struct LoudnessMeasurementDeferralTests {
    private static let url = URL(fileURLWithPath: "/track-switch-tests/loudness.wav")

    @Test func storedGainAppliesWithoutWaitingOrMeasuring() async throws {
        let recorder = DeferralRecorder()
        let fixture = DeferralFixture(cachedGain: 5, recorder: recorder) {
            recorder.enterWait()
            try await Task.sleep(for: .seconds(60))
        }
        let task = try #require(await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.url)
            return $0.pendingTask
        })
        await task.value

        #expect(await fixture.onQueue { $0.gainForPlayback } == 5)
        #expect(recorder.waitCount == 0)
        #expect(recorder.measuredLabels.isEmpty)
    }

    @Test func uncachedMeasurementWaitsAndCancellationDuringTheWaitSkipsIt() async throws {
        let recorder = DeferralRecorder()
        let fixture = DeferralFixture(cachedGain: nil, recorder: recorder) {
            recorder.enterWait()
            try await Task.sleep(for: .seconds(60))
        }
        let task = try #require(await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.url)
            return $0.pendingTask
        })
        try #require(await recorder.waitEntered.waitAsync(timeout: .now() + 5) == .success)
        #expect(recorder.measuredLabels.isEmpty)

        await fixture.onQueue { $0.cancel() }
        await task.value
        #expect(recorder.measuredLabels.isEmpty)
        #expect(await fixture.onQueue { $0.gainForPlayback } == 0)
        #expect(recorder.appliedGains.allSatisfy { $0 == 0 })
    }

    @Test func uncachedMeasurementRunsOnTheBlockingQueueAfterTheWait() async throws {
        let recorder = DeferralRecorder()
        let fixture = DeferralFixture(cachedGain: nil, recorder: recorder) { recorder.enterWait() }
        let task = try #require(await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.url)
            return $0.pendingTask
        })
        await task.value

        #expect(await fixture.onQueue { $0.gainForPlayback } == 4)
        #expect(recorder.waitCount == 1)
        #expect(recorder.measuredLabels == [blockingWorkQueueLabel])
    }
}

@MainActor
private final class LoadProbe {
    let engine: AudioEngineService
    var loadedDurations: [TimeInterval] = []
    var errors: [String] = []

    init(engine: AudioEngineService) {
        self.engine = engine
        engine.onFormatLoaded = { [weak self] duration, _ in self?.loadedDurations.append(duration) }
        engine.onError = { [weak self] message in self?.errors.append(message) }
    }
}

nonisolated private final class PreparationProbe: @unchecked Sendable {
    private let next: URL
    private let opened = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var steps = 0
    private var openedFirst: Bool?
    private var labels: [String] = []

    init(next: URL) { self.next = next }

    var fadeStepCount: Int { lock.withLock { steps } }
    var openedBeforeFadeEnded: Bool? { lock.withLock { openedFirst } }
    var queueLabels: [String] { lock.withLock { labels } }

    func open(_ url: URL) throws -> ExtendedAudioCache.ReadableFile {
        let label = currentQueueLabel()
        lock.withLock { labels.append(label) }
        if url == next { opened.signal() }
        return ExtendedAudioCache.ReadableFile(url: url)
    }

    // Runs on the control queue. The first fade step waits for the next track to be opened, which timed out
    // when preparation started only after the fade.
    func fadeStep() {
        let isFirst = lock.withLock {
            steps += 1
            return steps == 1
        }
        guard isFirst else { return }
        let result = opened.wait(timeout: .now() + 2) == .success
        lock.withLock { openedFirst = result }
    }
}

nonisolated private final class LabelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []

    var values: [String] { lock.withLock { labels } }

    func record() {
        let label = currentQueueLabel()
        lock.withLock { labels.append(label) }
    }
}

nonisolated private final class DeferralRecorder: @unchecked Sendable {
    let waitEntered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var waits = 0
    private var labels: [String] = []
    private var gains: [Float] = []

    var waitCount: Int { lock.withLock { waits } }
    var measuredLabels: [String] { lock.withLock { labels } }
    var appliedGains: [Float] { lock.withLock { gains } }

    func enterWait() {
        lock.withLock { waits += 1 }
        waitEntered.signal()
    }

    func measure() -> Float {
        let label = currentQueueLabel()
        lock.withLock { labels.append(label) }
        return 4
    }

    func apply(_ gain: Float) { lock.withLock { gains.append(gain) } }
}

nonisolated private final class DeferralFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LoudnessMeasurementDeferralTests.control")
    private let normalization: AudioLoudnessNormalization

    init(cachedGain: Float?, recorder: DeferralRecorder, wait: @escaping @Sendable () async throws -> Void) {
        normalization = AudioLoudnessNormalization(
            controlQueue: queue,
            cachedGain: { _ in cachedGain },
            measure: { _ in recorder.measure() },
            waitBeforeMeasuring: wait,
            applyGain: { recorder.apply($0) }
        )
    }

    func onQueue<Value: Sendable>(
        _ operation: @escaping @Sendable (AudioLoudnessNormalization) -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation(self.normalization)) }
        }
    }
}

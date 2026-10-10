import Foundation
import Testing
@testable import SimpleMediaPlayer
// Limit blocking measurement stubs to one test at a time, including parameterized cases.
@Suite(.serialized)
struct AudioLoudnessNormalizationTests {
    @Test func measurementDoesNotBlockPlaybackControlQueue() async throws {
        let measurement = ControlledLoudnessMeasurement(gain: 4)
        let fixture = LoudnessNormalizationFixture(measurements: [measurement])
        defer { measurement.release() }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { measurement.hasStarted }
        let gainWhileMeasuring = await fixture.onQueue { $0.gainForPlayback }

        #expect(measurement.hasReturned == false)
        #expect(gainWhileMeasuring == 0)
        await fixture.onQueue { $0.cancel() }
        try await waitFor { measurement.wasCancelled }
    }

    @Test(arguments: CancellationAction.allCases)
    private func stoppingDisablingOrUnloadingCancelsMeasurement(action: CancellationAction) async throws {
        let measurement = ControlledLoudnessMeasurement(gain: 4)
        let fixture = LoudnessNormalizationFixture(measurements: [measurement])
        defer { measurement.release() }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { measurement.hasStarted }
        await fixture.onQueue { normalization in
            switch action {
            case .stop: normalization.cancel()
            case .disable: normalization.setEnabled(false)
            case .unload: normalization.load(nil)
            }
        }
        try await waitFor { measurement.wasCancelled }

        #expect(await fixture.onQueue { $0.gainForPlayback } == 0)
        #expect(fixture.appliedGains.allSatisfy { $0 == 0 })
    }

    @Test func selectingAnotherTrackCancelsPreviousMeasurementAndClearsGain() async throws {
        let first = ControlledLoudnessMeasurement(gain: 4)
        let second = ControlledLoudnessMeasurement(gain: -5)
        let fixture = LoudnessNormalizationFixture(measurements: [first, second])
        defer {
            first.release()
            second.release()
        }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { first.hasStarted }
        await fixture.onQueue { $0.load(Self.secondURL) }
        try await waitFor { first.wasCancelled && second.hasStarted }

        #expect(await fixture.onQueue { $0.gainForPlayback } == 0)
        second.release()
        try await waitFor { fixture.appliedGains.contains(-5) }
        #expect(await fixture.onQueue { $0.gainForPlayback } == -5)
        #expect(fixture.appliedGains.contains(4) == false)
    }

    @Test func stoppedMeasurementCanResumeForTheSameTrack() async throws {
        let first = ControlledLoudnessMeasurement(gain: 4)
        let resumed = ControlledLoudnessMeasurement(gain: 6)
        let fixture = LoudnessNormalizationFixture(measurements: [first, resumed])
        defer {
            first.release()
            resumed.release()
        }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { first.hasStarted }
        await fixture.onQueue { $0.cancel() }
        try await waitFor { first.wasCancelled }
        await fixture.onQueue { $0.resume() }
        try await waitFor { resumed.hasStarted }
        resumed.release()
        try await waitFor { fixture.appliedGains.contains(6) }

        await fixture.onQueue { $0.resume() }
        #expect(await fixture.onQueue { $0.gainForPlayback } == 6)
        #expect(fixture.requestedURLs == [Self.firstURL, Self.firstURL])
    }

    @Test func disabledNormalizationDefersMeasurementAndReusesCompletedGain() async throws {
        let measurement = ControlledLoudnessMeasurement(gain: 3)
        let fixture = LoudnessNormalizationFixture(measurements: [measurement])
        defer { measurement.release() }

        await fixture.onQueue {
            $0.load(Self.firstURL)
            $0.resume()
        }
        #expect(fixture.requestedURLs.isEmpty)
        #expect(await fixture.onQueue { $0.gainForPlayback } == 0)

        await fixture.onQueue { $0.setEnabled(true) }
        try await waitFor { measurement.hasStarted }
        measurement.release()
        try await waitFor { fixture.appliedGains.contains(3) }
        await fixture.onQueue { $0.setEnabled(false) }
        #expect(await fixture.onQueue { $0.gainForPlayback } == 0)
        await fixture.onQueue { $0.setEnabled(true) }

        #expect(await fixture.onQueue { $0.gainForPlayback } == 3)
        #expect(fixture.requestedURLs == [Self.firstURL])
        #expect(fixture.appliedGains.last == 3)
    }

    @Test func loadingANewTrackDiscardsPreviouslyMeasuredGain() async throws {
        let first = ControlledLoudnessMeasurement(gain: 7)
        let second = ControlledLoudnessMeasurement(gain: -2)
        let fixture = LoudnessNormalizationFixture(measurements: [first, second])
        defer {
            first.release()
            second.release()
        }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { first.hasStarted }
        first.release()
        try await waitFor { fixture.appliedGains.contains(7) }
        await fixture.onQueue { $0.load(Self.secondURL) }
        try await waitFor { second.hasStarted }

        #expect(await fixture.onQueue { $0.gainForPlayback } == 0)
        #expect(fixture.appliedGains.last == 0)
        await fixture.onQueue { $0.cancel() }
        try await waitFor { second.wasCancelled }
    }

    @Test(arguments: ReplacementAction.allCases)
    private func noncooperativeOldMeasurementCannotReplaceCurrentGain(action: ReplacementAction) async throws {
        let first = ControlledLoudnessMeasurement(gain: 9, ignoresCancellation: true)
        let second = ControlledLoudnessMeasurement(gain: -3)
        let fixture = LoudnessNormalizationFixture(measurements: [first, second])
        defer {
            first.release()
            second.release()
        }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { first.hasStarted }
        let oldTask = try #require(await fixture.onQueue { $0.pendingTask })
        await fixture.onQueue { normalization in
            switch action {
            case .stopAndResume:
                normalization.cancel()
                normalization.resume()
            case .disableAndEnable:
                normalization.setEnabled(false)
                normalization.setEnabled(true)
            case .replaceTrack:
                normalization.load(Self.secondURL)
            case .reloadSameTrack:
                normalization.load(Self.firstURL)
            }
        }
        try await waitFor { second.hasStarted }
        let currentTask = try #require(await fixture.onQueue { $0.pendingTask })
        second.release()
        await currentTask.value
        #expect(await fixture.onQueue { $0.gainForPlayback } == -3)

        first.release()
        await oldTask.value

        #expect(await fixture.onQueue { $0.gainForPlayback } == -3)
        #expect(fixture.appliedGains.contains(9) == false)
    }

    @Test func queuedResultIsDiscardedAfterTrackChangesBeforeApplication() async throws {
        let first = ControlledLoudnessMeasurement(gain: 9)
        let second = ControlledLoudnessMeasurement(gain: -3)
        let fixture = LoudnessNormalizationFixture(measurements: [first, second])
        let queueEntered = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        defer {
            releaseQueue.signal()
            first.release()
            second.release()
        }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { first.hasStarted }
        let oldTask = try #require(await fixture.onQueue { $0.pendingTask })
        fixture.enqueueOnQueue { normalization in
            queueEntered.signal()
            guard releaseQueue.wait(timeout: .now() + 5) == .success else {
                Issue.record("Timed out waiting to release the playback control queue.")
                return
            }
            normalization.load(Self.secondURL)
        }
        try await waitFor { queueEntered.wait(timeout: .now()) == .success }
        first.release()
        await oldTask.value
        releaseQueue.signal()

        #expect(await fixture.onQueue { $0.gainForPlayback } == 0)
        #expect(fixture.appliedGains.contains(9) == false)
        try await waitFor { second.hasStarted }
        let currentTask = try #require(await fixture.onQueue { $0.pendingTask })
        second.release()
        await currentTask.value
        #expect(await fixture.onQueue { $0.gainForPlayback } == -3)
    }

    @Test(arguments: [
        GainSample(measured: 5, expected: 5),
        GainSample(measured: -100, expected: AudioLoudnessNormalizer.minimumGainDecibels),
        GainSample(measured: 100, expected: AudioLoudnessNormalizer.maximumGainDecibels),
        GainSample(measured: .nan, expected: 0),
        GainSample(measured: .infinity, expected: 0),
        GainSample(measured: -.infinity, expected: 0)
    ])
    private func completedMeasurementAppliesOnlyFiniteBoundedGain(sample: GainSample) async throws {
        let measurement = ControlledLoudnessMeasurement(gain: sample.measured)
        let fixture = LoudnessNormalizationFixture(measurements: [measurement])
        defer { measurement.release() }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { measurement.hasStarted }
        let task = try #require(await fixture.onQueue { $0.pendingTask })
        measurement.release()
        await task.value

        #expect(await fixture.onQueue { $0.gainForPlayback } == sample.expected)
        #expect(fixture.appliedGains.last == sample.expected)
    }

    @Test func failedMeasurementLeavesUnityGainAndDoesNotRestartOnResume() async throws {
        let measurement = ControlledLoudnessMeasurement(gain: 8, fails: true)
        let fixture = LoudnessNormalizationFixture(measurements: [measurement])
        defer { measurement.release() }

        await fixture.onQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        try await waitFor { measurement.hasStarted }
        let task = try #require(await fixture.onQueue { $0.pendingTask })
        measurement.release()
        await task.value
        await fixture.onQueue { $0.resume() }

        #expect(await fixture.onQueue { $0.gainForPlayback } == 0)
        #expect(fixture.appliedGains.allSatisfy { $0 == 0 })
        #expect(fixture.requestedURLs == [Self.firstURL])
    }

    @Test func releasingNormalizationCancelsItsMeasurement() async throws {
        let measurement = ControlledLoudnessMeasurement(gain: 8)
        let queue = DispatchQueue(label: "AudioLoudnessNormalizationTests.deinit")
        let recording = LoudnessMeasurementRecording(measurements: [measurement])
        let owner = LoudnessNormalizationOwner()
        defer { measurement.release() }

        queue.sync {
            owner.normalization = AudioLoudnessNormalization(
                controlQueue: queue,
                cachedGain: { _ in nil },
                measure: { url in try recording.measure(url: url) },
                waitBeforeMeasuring: {},
                applyGain: { gain in recording.recordAppliedGain(gain) }
            )
            owner.normalization?.setEnabled(true)
            owner.normalization?.load(Self.firstURL)
        }
        try await waitFor { measurement.hasStarted }
        let task = try #require(queue.sync { owner.normalization?.pendingTask })

        queue.sync { owner.normalization = nil }
        await task.value

        #expect(measurement.wasCancelled)
        #expect(recording.appliedGains.allSatisfy { $0 == 0 })
    }

    private struct GainSample: Sendable {
        let measured: Float
        let expected: Float
    }

    private enum ReplacementAction: CaseIterable, Sendable {
        case stopAndResume
        case disableAndEnable
        case replaceTrack
        case reloadSameTrack
    }

    private enum CancellationAction: CaseIterable, Sendable {
        case stop
        case disable
        case unload
    }

    private static let firstURL = URL(fileURLWithPath: "/loudness-tests/first.wav")
    private static let secondURL = URL(fileURLWithPath: "/loudness-tests/second.wav")
    private func waitFor(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the controlled loudness measurement.")
                throw LoudnessMeasurementTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class LoudnessNormalizationOwner: @unchecked Sendable {
    var normalization: AudioLoudnessNormalization?
}

private final class LoudnessNormalizationFixture: @unchecked Sendable {
    private let controlQueue = DispatchQueue(label: "AudioLoudnessNormalizationTests.control")
    private let recording: LoudnessMeasurementRecording
    private let normalization: AudioLoudnessNormalization

    init(measurements: [ControlledLoudnessMeasurement]) {
        let recording = LoudnessMeasurementRecording(measurements: measurements)
        self.recording = recording
        normalization = AudioLoudnessNormalization(
            controlQueue: controlQueue,
            cachedGain: { _ in nil },
            measure: { url in try recording.measure(url: url) },
            waitBeforeMeasuring: {},
            applyGain: { gain in recording.recordAppliedGain(gain) }
        )
    }

    var appliedGains: [Float] { recording.appliedGains }
    var requestedURLs: [URL] { recording.requestedURLs }

    func enqueueOnQueue(_ operation: @escaping @Sendable (AudioLoudnessNormalization) -> Void) {
        controlQueue.async { operation(self.normalization) }
    }

    func onQueue<Value: Sendable>(
        _ operation: @escaping @Sendable (AudioLoudnessNormalization) -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                continuation.resume(returning: operation(self.normalization))
            }
        }
    }
}

private final class LoudnessMeasurementRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var measurements: [ControlledLoudnessMeasurement]
    private var gains: [Float] = []
    private var urls: [URL] = []

    init(measurements: [ControlledLoudnessMeasurement]) {
        self.measurements = measurements
    }

    var appliedGains: [Float] { lock.withLock { gains } }
    var requestedURLs: [URL] { lock.withLock { urls } }

    func measure(url: URL) throws -> Float {
        let measurement = lock.withLock {
            urls.append(url)
            return measurements.isEmpty ? nil : measurements.removeFirst()
        }
        guard let measurement else { throw LoudnessMeasurementTestError.unexpectedMeasurement }
        return try measurement.measure()
    }

    func recordAppliedGain(_ gain: Float) {
        lock.withLock { gains.append(gain) }
    }
}

private final class ControlledLoudnessMeasurement: @unchecked Sendable {
    private let condition = NSCondition()
    private let gain: Float
    private let ignoresCancellation: Bool
    private let fails: Bool
    private var started = false
    private var returned = false
    private var cancelled = false
    private var released = false

    init(gain: Float, ignoresCancellation: Bool = false, fails: Bool = false) {
        self.gain = gain
        self.ignoresCancellation = ignoresCancellation
        self.fails = fails
    }

    var hasStarted: Bool { condition.withLock { started } }
    var hasReturned: Bool { condition.withLock { returned } }
    var wasCancelled: Bool { condition.withLock { cancelled } }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

    func measure() throws -> Float {
        condition.lock()
        started = true
        let deadline = Date().addingTimeInterval(5)
        defer {
            returned = true
            condition.unlock()
        }
        while released == false {
            if ignoresCancellation == false, Task.isCancelled {
                cancelled = true
                throw CancellationError()
            }
            guard Date() < deadline else { throw LoudnessMeasurementTestError.timeout }
            condition.wait(until: Date().addingTimeInterval(0.005))
        }
        if fails { throw LoudnessMeasurementTestError.measurementFailed }
        return gain
    }
}

private enum LoudnessMeasurementTestError: Error {
    case timeout
    case unexpectedMeasurement
    case measurementFailed
}

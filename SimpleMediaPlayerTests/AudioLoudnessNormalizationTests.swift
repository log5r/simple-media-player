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

        let setupProbe = PlaybackControlQueueProbe()
        fixture.enqueueOnQueue {
            $0.setEnabled(true)
            $0.load(Self.firstURL)
        }
        fixture.enqueueOnQueue { _ in setupProbe.record() }
        try await waitForControlledMeasurement("control queue setup response", timeout: .seconds(1)) {
            setupProbe.hasResponded
        }

        try await waitForControlledMeasurement("measurement start", timeout: .seconds(30)) {
            measurement.hasStarted
        }

        let gainProbe = PlaybackControlQueueProbe()
        fixture.enqueueOnQueue { normalization in
            gainProbe.record(normalization.gainForPlayback)
        }
        try await waitForControlledMeasurement("control queue response while measuring", timeout: .seconds(1)) {
            gainProbe.hasResponded
        }

        #expect(measurement.hasReturned == false)
        #expect(gainProbe.value == 0)
        fixture.enqueueOnQueue { $0.cancel() }
        try await waitForControlledMeasurement("measurement cancellation", timeout: .seconds(5)) {
            measurement.wasCancelled
        }
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

    private enum CancellationAction: CaseIterable, Sendable {
        case stop
        case disable
        case unload
    }

    static let firstURL = URL(fileURLWithPath: "/loudness-tests/first.wav")
    static let secondURL = URL(fileURLWithPath: "/loudness-tests/second.wav")
    func waitFor(_ condition: @escaping @Sendable () -> Bool) async throws {
        try await waitForControlledMeasurement(
            "controlled loudness measurement", timeout: .seconds(5), condition: condition
        )
    }

    func waitForControlledMeasurement(
        _ description: String,
        timeout: Duration,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(description).")
                throw LoudnessMeasurementTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

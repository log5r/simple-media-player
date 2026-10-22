import Foundation
import Testing
@testable import SimpleMediaPlayer

extension AudioLoudnessNormalizationTests {
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
}

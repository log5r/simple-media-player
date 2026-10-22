import Foundation
import Testing
@testable import SimpleMediaPlayer

final class LoudnessNormalizationOwner: @unchecked Sendable {
    var normalization: AudioLoudnessNormalization?
}

final class LoudnessNormalizationFixture: @unchecked Sendable {
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

final class LoudnessMeasurementRecording: @unchecked Sendable {
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

final class ControlledLoudnessMeasurement: @unchecked Sendable {
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
        let deadline = Date().addingTimeInterval(60)
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

final class PlaybackControlQueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue: Float?
    private var responded = false

    var hasResponded: Bool { lock.withLock { responded } }
    var value: Float? { lock.withLock { recordedValue } }

    func record(_ value: Float? = nil) {
        lock.withLock {
            recordedValue = value
            responded = true
        }
    }
}

enum LoudnessMeasurementTestError: Error {
    case timeout
    case unexpectedMeasurement
    case measurementFailed
}

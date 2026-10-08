import Foundation
import Synchronization

/// Decides which progress reports from a background loop are worth forwarding to the main actor.
///
/// A report passes when it advances at least `minimumStep` past the last forwarded value, when at least
/// `minimumInterval` has elapsed since the last forwarded report, or when it reaches completion.
/// Reports that do not advance the value never pass.
nonisolated final class ProgressReportThrottle: Sendable {
    static let defaultMinimumStep = 0.01
    static let defaultMinimumInterval = Duration.milliseconds(100)

    private struct State {
        var lastValue: Double?
        var lastReportTime: ContinuousClock.Instant?
    }

    private let minimumStep: Double
    private let minimumInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())

    init(
        minimumStep: Double = defaultMinimumStep,
        minimumInterval: Duration = defaultMinimumInterval,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.minimumStep = minimumStep
        self.minimumInterval = minimumInterval
        self.now = now
    }

    func shouldReport(_ value: Double) -> Bool {
        let time = now()
        return state.withLock { state in
            if let lastValue = state.lastValue {
                guard value > lastValue else { return false }
                let advancedEnough = value - lastValue >= minimumStep
                let waitedEnough = state.lastReportTime.map { $0.duration(to: time) >= minimumInterval } ?? true
                guard value >= 1 || advancedEnough || waitedEnough else { return false }
            }
            state.lastValue = value
            state.lastReportTime = time
            return true
        }
    }
}

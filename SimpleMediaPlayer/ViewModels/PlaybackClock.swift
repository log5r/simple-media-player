import Foundation
import Observation

/// Keep second displays and transport availability independent of fractional clock ticks.
@MainActor
@Observable
final class PlaybackClock {
    private(set) var time: TimeInterval = 0
    private(set) var elapsedSeconds = 0
    private(set) var canRestart = false

    func update(to value: TimeInterval) {
        let value = value.isFinite ? max(0, value) : 0
        if time != value { time = value }
        let seconds = Int(min(value.rounded(.down), Double(Int.max).nextDown))
        if elapsedSeconds != seconds { elapsedSeconds = seconds }
        let canRestart = value >= 3
        if self.canRestart != canRestart { self.canRestart = canRestart }
    }
}

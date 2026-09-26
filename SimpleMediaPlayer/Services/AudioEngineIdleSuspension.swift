import Foundation

// All state and scheduled callbacks belong to the playback control queue.
nonisolated final class AudioEngineIdleSuspension: @unchecked Sendable {
    typealias Schedule = @Sendable (TimeInterval, DispatchWorkItem) -> Void

    private let controlQueue: DispatchQueue
    private let schedule: Schedule
    private var generation = 0
    private var pendingWork: DispatchWorkItem?

    init(controlQueue: DispatchQueue, schedule: Schedule? = nil) {
        self.controlQueue = controlQueue
        self.schedule = schedule ?? { delay, work in
            controlQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    deinit {
        pendingWork?.cancel()
    }

    func request(settings: EqualizerSettings, suspend: @escaping @Sendable () -> Void) {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        cancel()
        let generation = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.controlQueue))
            guard self.generation == generation else { return }
            self.pendingWork = nil
            self.generation += 1
            suspend()
        }
        pendingWork = work
        schedule(Self.tailDuration(for: settings), work)
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        generation += 1
        pendingWork?.cancel()
        pendingWork = nil
    }

    static func tailDuration(for settings: EqualizerSettings) -> TimeInterval {
        guard settings.isEnabled,
              EqualizerSettings.clampedReverbWetDryMix(settings.reverbWetDryMix) > 0 else {
            return 0.25
        }
        switch settings.reverbPreset {
        case .smallRoom: return 1
        case .mediumRoom: return 1.5
        case .largeHall: return 3
        }
    }
}

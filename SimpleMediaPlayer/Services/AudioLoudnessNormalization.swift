import Foundation

// State and gain application belong to the playback control queue; measurement does not.
nonisolated final class AudioLoudnessNormalization: @unchecked Sendable {
    private let controlQueue: DispatchQueue
    private let measure: @Sendable (URL) throws -> Float
    private let applyGain: @Sendable (Float) -> Void
    private var currentURL: URL?
    private var isEnabled = false
    private var measuredGain: Float?
    private var generation = 0
    private var task: Task<Void, Never>?

    init(
        controlQueue: DispatchQueue,
        measure: @escaping @Sendable (URL) throws -> Float = {
            try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: $0)
        },
        applyGain: @escaping @Sendable (Float) -> Void
    ) {
        self.controlQueue = controlQueue
        self.measure = measure
        self.applyGain = applyGain
    }

    deinit {
        task?.cancel()
    }

    var gainForPlayback: Float {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        return isEnabled ? measuredGain ?? 0 : 0
    }

    var pendingTask: Task<Void, Never>? {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        return task
    }

    func setEnabled(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled == false { cancel() }
        applyGain(gainForPlayback)
        resume()
    }

    func load(_ url: URL?) {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        cancel()
        currentURL = url
        measuredGain = nil
        applyGain(0)
        resume()
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        generation += 1
        task?.cancel()
        task = nil
    }

    func resume() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard isEnabled, measuredGain == nil, task == nil, let url = currentURL else { return }
        let generation = generation
        task = Task.detached(priority: .utility) { [weak self, measure, controlQueue] in
            let gain: Float?
            do {
                try Task.checkCancellation()
                let measuredGain = try measure(url)
                try Task.checkCancellation()
                gain = measuredGain
            } catch {
                gain = Task.isCancelled || error is CancellationError ? nil : 0
            }
            controlQueue.async { [weak self] in
                guard let self,
                      self.generation == generation,
                      self.currentURL == url,
                      self.isEnabled else { return }
                self.task = nil
                guard let gain else { return }
                let clampedGain = gain.isFinite
                    ? max(
                        AudioLoudnessNormalizer.minimumGainDecibels,
                        min(AudioLoudnessNormalizer.maximumGainDecibels, gain)
                    )
                    : 0
                self.measuredGain = clampedGain
                self.applyGain(clampedGain)
            }
        }
    }
}

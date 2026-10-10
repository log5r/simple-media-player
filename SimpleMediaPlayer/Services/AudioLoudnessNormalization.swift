import Foundation

// State and gain application belong to the playback control queue; measurement does not.
nonisolated final class AudioLoudnessNormalization: @unchecked Sendable {
    private let controlQueue: DispatchQueue
    private let cachedGain: @Sendable (URL) -> Float?
    private let measure: @Sendable (URL) async throws -> Float
    private let waitBeforeMeasuring: @Sendable () async throws -> Void
    private let applyGain: @Sendable (Float) -> Void
    private var currentURL: URL?
    private var isEnabled = false
    private var measuredGain: Float?
    private var generation = 0
    private var task: Task<Void, Never>?

    /// A stored gain applies at once. Reading the whole file waits `waitBeforeMeasuring` first, so that it does
    /// not compete with the first reads of the track that has just started.
    init(
        controlQueue: DispatchQueue,
        cachedGain: @escaping @Sendable (URL) -> Float? = { AudioLoudnessNormalizer.cachedGain(for: $0) },
        measure: @escaping @Sendable (URL) async throws -> Float = { url in
            try await ExtendedAudioSource.withCancellableCacheWaits {
                try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url)
            }
        },
        waitBeforeMeasuring: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        applyGain: @escaping @Sendable (Float) -> Void
    ) {
        self.controlQueue = controlQueue
        self.cachedGain = cachedGain
        self.measure = measure
        self.waitBeforeMeasuring = waitBeforeMeasuring
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
        task = Task.detached(
            executorPreference: BlockingWorkExecutor.shared, priority: .utility
        ) { [weak self, cachedGain, measure, waitBeforeMeasuring, controlQueue] in
            let gain: Float?
            do {
                try Task.checkCancellation()
                if let storedGain = cachedGain(url) {
                    gain = storedGain
                } else {
                    try await waitBeforeMeasuring()
                    try Task.checkCancellation()
                    let measuredGain = try await measure(url)
                    try Task.checkCancellation()
                    gain = measuredGain
                }
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

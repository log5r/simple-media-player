import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
final class ConfigurationRecoveryFixture {
    let source: PitchProcessingSource
    let replacement: PitchProcessingSource
    let service: AudioEngineService
    let probe = ConfigurationRecoveryProbe()
    private(set) var loadCount = 0
    private(set) var finishCount = 0
    private(set) var errors: [String] = []

    init(seconds: Int = 5) async throws {
        source = try PitchProcessingSource(
            sampleRate: 48_000, channelCount: 1,
            samples: [Float](repeating: 0, count: 48_000 * seconds)
        )
        replacement = try PitchProcessingSource(
            sampleRate: 48_000, channelCount: 1,
            samples: [Float](repeating: 0, count: 48_000 * 3)
        )
        let probe = probe
        service = AudioEngineService(
            analyzer: SpectrumAnalyzer(),
            openReadableFile: { ExtendedAudioCache.ReadableFile(url: $0) },
            waitForFadeStep: { _ in probe.recordFadeStep() },
            engineFactory: { probe.makeEngine() },
            preparePlayer: { probe.prepare($0, frameCount: $1) }
        )
        service.onFormatLoaded = { [weak self] _, _ in self?.loadCount += 1 }
        service.onFinished = { [weak self] in self?.finishCount += 1 }
        service.onError = { [weak self] in self?.errors.append($0) }
        service.load(url: source.url)
        try await waitUntil { self.loadCount == 1 }
        service.play()
        try #require(await service.isEngineRunning)
        try await waitUntil { self.service.currentTime > 0.02 }
    }

    func beginRecovery() async throws -> AVAudioEngine {
        // Drain earlier service work before simulating the system stopping its
        // engine. No user work is queued until recovery reaches the preparation gate.
        try #require(await service.isEngineRunning)
        let nativeEngine = try probe.latestEngine()
        probe.holdNextPreparation()
        nativeEngine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nativeEngine)
        try #require(await probe.preparationEntered.waitAsync(timeout: .now() + 5) == .success)
        return nativeEngine
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    func remove() {
        probe.releasePreparation()
        service.suspend()
        source.remove()
        replacement.remove()
    }
}

nonisolated final class ConfigurationRecoveryProbe: @unchecked Sendable {
    let preparationEntered = DispatchSemaphore(value: 0)
    private let preparationGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var engines: [AVAudioEngine] = []
    private var preparationCountStorage = 0
    private var fadeStepCountStorage = 0
    private var shouldHoldPreparation = false

    var engineCount: Int { lock.withLock { engines.count } }
    var preparationCount: Int { lock.withLock { preparationCountStorage } }
    var fadeStepCount: Int { lock.withLock { fadeStepCountStorage } }

    func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        lock.withLock { engines.append(engine) }
        return engine
    }

    func latestEngine() throws -> AVAudioEngine {
        try #require(lock.withLock { engines.last })
    }

    func holdNextPreparation() {
        lock.withLock { shouldHoldPreparation = true }
    }

    func prepare(_ player: AVAudioPlayerNode, frameCount: AVAudioFrameCount) {
        player.prepare(withFrameCount: frameCount)
        let shouldWait = lock.withLock {
            preparationCountStorage += 1
            let shouldWait = shouldHoldPreparation
            shouldHoldPreparation = false
            return shouldWait
        }
        guard shouldWait else { return }
        preparationEntered.signal()
        #expect(preparationGate.wait(timeout: .now() + 10) == .success)
    }

    func releasePreparation() {
        preparationGate.signal()
    }

    func recordFadeStep() {
        lock.withLock { fadeStepCountStorage += 1 }
    }
}

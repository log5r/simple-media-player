import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.serialized)
struct AudioEnginePlayFailureTests {
    @Test func aFailedPlayerStartReportsOnceAndTheNextPlayStartsCleanly() async throws {
        let source = try PitchProcessingSource(
            sampleRate: 48_000, channelCount: 1, samples: [Float](repeating: 0, count: 48_000)
        )
        defer { source.remove() }
        let failure = PlayerStartFailure()
        let service = AudioEngineService(
            analyzer: SpectrumAnalyzer(),
            openReadableFile: { ExtendedAudioCache.ReadableFile(url: $0) },
            waitForFadeStep: { _ in },
            preparePlayer: { player, frameCount in
                player.prepare(withFrameCount: frameCount)
                // Runs after the segment is scheduled; a stopped engine makes playAudio() throw.
                if failure.consume() { player.engine?.stop() }
            }
        )
        defer { service.suspend() }
        var loaded = false
        var finishCount = 0
        var errors: [String] = []
        service.onFormatLoaded = { _, _ in loaded = true }
        service.onFinished = { finishCount += 1 }
        service.onError = { errors.append($0) }
        service.load(url: source.url)
        try await waitUntil { loaded }

        failure.arm()
        service.play()
        try await waitUntil { errors.count == 1 }
        #expect(await service.isEngineRunning == false)
        #expect(service.stateLock.withLock { service.displayIsPlaying } == false)
        #expect(service.currentTime == 0)

        service.play()
        #expect(await service.isEngineRunning)
        try await waitUntil { service.currentTime > 0.05 }
        try await waitUntil { finishCount == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(finishCount == 1)
        #expect(errors.count == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

nonisolated private final class PlayerStartFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false

    func arm() { lock.withLock { isArmed = true } }

    func consume() -> Bool {
        lock.withLock {
            defer { isArmed = false }
            return isArmed
        }
    }
}

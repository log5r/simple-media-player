import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.serialized)
struct AudioEnginePreparationSuspensionTests {
    @Test func preparationCompletingBeforeTheDeadlineCancelsTheOldSuspension() async throws {
        let fixture = try await PreparationSuspensionFixture()
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: true)
        fixture.preparation.complete()
        try await fixture.waitForLoads(2)

        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning)
        #expect(fixture.errors.isEmpty)
    }

    @Test func playbackPreparationKeepsTheRunningEnginePastTheTailDeadline() async throws {
        let fixture = try await PreparationSuspensionFixture()
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: true)
        #expect(fixture.deadlines.delays == [0.25])

        fixture.deadlines.fire(at: 0)
        #expect(await fixture.engine.isEngineRunning)
        fixture.preparation.complete()
        try await fixture.waitForLoads(2)
        #expect(await fixture.engine.isEngineRunning)
        #expect(fixture.errors.isEmpty)

        fixture.engine.stop(reset: true)
        _ = await fixture.engine.isEngineRunning
        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning == false)
    }

    @Test func preparationWithoutPlaybackAllowsIdleSuspension() async throws {
        let fixture = try await PreparationSuspensionFixture()
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: false)

        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning == false)
        fixture.preparation.complete()
        try await fixture.waitForLoads(2)
        #expect(await fixture.engine.isEngineRunning == false)
    }

    @Test(arguments: PreparationEnd.allCases)
    func unsuccessfulPreparationRestoresIdleSuspension(_ end: PreparationEnd) async throws {
        let fixture = try await PreparationSuspensionFixture(end: end)
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: true)
        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning)

        fixture.preparation.complete()
        try await waitForCondition { fixture.deadlines.delays.count == 2 }
        fixture.engine.play() // There is no prepared audio; this must not cancel idle work.
        _ = await fixture.engine.isEngineRunning
        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning == false)
        #expect(fixture.engine.duration == 0)
        if end == .failure { try await waitForCondition { fixture.errors.count == 1 } }
        if end == .cancellation { #expect(fixture.errors.isEmpty) }
    }

    @Test(arguments: PreparationPlaybackChange.allCases)
    func stoppingThePendingPlaybackAllowsTheEngineToSuspend(_ change: PreparationPlaybackChange) async throws {
        let fixture = try await PreparationSuspensionFixture()
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: true)
        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning)

        switch change {
        case .stop: fixture.engine.stop(reset: true)
        case .pause: fixture.engine.pause()
        case .seek: fixture.engine.seek(to: 1, autoPlay: false)
        }
        _ = await fixture.engine.isEngineRunning
        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning == false)
        fixture.preparation.complete()
        try await fixture.waitForLoads(2)
        #expect(await fixture.engine.isEngineRunning == false)
        #expect(fixture.errors.isEmpty)
    }

    @Test func aLaterPlayOverridesAPendingPausedSeek() async throws {
        let fixture = try await PreparationSuspensionFixture()
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: false)
        fixture.engine.seek(to: 1, autoPlay: false)
        fixture.engine.play()
        _ = await fixture.engine.isEngineRunning
        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning)

        fixture.preparation.complete()
        try await fixture.waitForLoads(2)
        #expect(await fixture.engine.isEngineRunning)
        try await waitForCondition { fixture.engine.currentTime > 1.05 }
    }

    @Test func anAutoplaySeekKeepsTheEngineReadyWithoutAnExplicitPlay() async throws {
        let fixture = try await PreparationSuspensionFixture()
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: false)
        fixture.engine.seek(to: 1, autoPlay: true)
        _ = await fixture.engine.isEngineRunning
        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning)

        fixture.preparation.complete()
        try await fixture.waitForLoads(2)
        #expect(await fixture.engine.isEngineRunning)
        try await waitForCondition { fixture.engine.currentTime > 1.05 }
    }

    @Test(arguments: PreparationInvalidation.allCases)
    func anOldCompletionCannotSuspendOrStartTheCurrentEngine(_ invalidation: PreparationInvalidation) async throws {
        let fixture = try await PreparationSuspensionFixture(end: .cancellation)
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: true)
        fixture.deadlines.fireLast()
        #expect(await fixture.engine.isEngineRunning)

        let oldPreparation = try #require(await fixture.engine.pendingPreparationTask)

        switch invalidation {
        case .load:
            fixture.engine.load(url: fixture.first)
            fixture.engine.play()
            try await fixture.waitForLoads(2)
        case .suspend: fixture.engine.suspend()
        }
        let running = await fixture.engine.isEngineRunning
        let deadlineCount = fixture.deadlines.delays.count
        fixture.preparation.complete()
        await oldPreparation.value
        _ = await fixture.engine.isEngineRunning
        // Fire every stale deadline as well, even if its work item was canceled.
        for index in fixture.deadlines.delays.indices { fixture.deadlines.fire(at: index) }
        #expect(await fixture.engine.isEngineRunning == running)
        #expect(fixture.deadlines.delays.count == deadlineCount)
        #expect(fixture.errors.isEmpty)
    }

    @Test func engineResetDuringPreparationResumesOnlyAfterTheFileArrives() async throws {
        let fixture = try await PreparationSuspensionFixture()
        defer { fixture.remove() }
        try await fixture.beginPreparation(play: true)
        fixture.engine.resetEngine()
        #expect(await fixture.engine.isEngineRunning == false)
        fixture.deadlines.fire(at: 0)
        #expect(await fixture.engine.isEngineRunning == false)

        fixture.preparation.complete()
        try await fixture.waitForLoads(2)
        #expect(await fixture.engine.isEngineRunning)
    }
}

nonisolated enum PreparationEnd: CaseIterable {
    case failure
    case cancellation
}

nonisolated enum PreparationPlaybackChange: CaseIterable {
    case stop
    case pause
    case seek
}

nonisolated enum PreparationInvalidation: CaseIterable {
    case load
    case suspend
}

@MainActor
private final class PreparationSuspensionFixture {
    let first: URL
    private let second: URL
    let preparation: GatedAudioPreparation
    let deadlines = ManualIdleDeadlines()
    let engine: AudioEngineService
    private var loadedCount = 0
    private(set) var errors: [String] = []

    init(end: PreparationEnd? = nil) async throws {
        first = try Self.makeAudio()
        second = try Self.makeAudio()
        preparation = GatedAudioPreparation(url: second, end: end)
        let preparation = preparation
        let deadlines = deadlines
        engine = AudioEngineService(
            analyzer: SpectrumAnalyzer(), openReadableFile: { try preparation.open($0) },
            waitForFadeStep: { _ in }, scheduleIdleSuspension: { deadlines.schedule($0, queue: $1, work: $2) }
        )
        engine.onFormatLoaded = { [weak self] _, _ in self?.loadedCount += 1 }
        engine.onError = { [weak self] in self?.errors.append($0) }
        engine.load(url: first)
        try await waitForLoads(1)
        engine.play()
        try #require(await engine.isEngineRunning)
    }

    func beginPreparation(play: Bool) async throws {
        engine.load(url: second)
        if play { engine.play() }
        try #require(await preparation.started.waitAsync(timeout: .now() + 5) == .success)
        _ = await engine.isEngineRunning
        try #require(deadlines.delays.count == 1)
    }

    func waitForLoads(_ count: Int) async throws {
        try await waitForCondition { self.loadedCount == count }
    }

    func remove() {
        preparation.complete()
        engine.suspend()
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    private static func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idle-preparation-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 10))
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

@MainActor
private func waitForCondition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
}

nonisolated private final class ManualIdleDeadlines: @unchecked Sendable {
    private struct Request {
        let delay: TimeInterval
        let queue: DispatchQueue
        let work: DispatchWorkItem
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    var delays: [TimeInterval] { lock.withLock { requests.map(\.delay) } }

    func schedule(_ delay: TimeInterval, queue: DispatchQueue, work: DispatchWorkItem) {
        lock.withLock { requests.append(Request(delay: delay, queue: queue, work: work)) }
    }

    func fire(at index: Int) {
        let request = lock.withLock { requests[index] }
        request.queue.async(execute: request.work)
    }
    func fireLast() { fire(at: delays.count - 1) }
}

nonisolated private final class GatedAudioPreparation: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let url: URL
    private let end: PreparationEnd?

    init(url: URL, end: PreparationEnd?) {
        self.url = url
        self.end = end
    }

    func open(_ candidate: URL) throws -> ExtendedAudioCache.ReadableFile {
        if candidate == url {
            started.signal()
            defer { finished.signal() }
            guard gate.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
            switch end {
            case .failure: throw CocoaError(.fileReadUnknown)
            case .cancellation: throw CancellationError()
            case nil: break
            }
        }
        return ExtendedAudioCache.ReadableFile(url: candidate)
    }

    func complete() { gate.signal() }
}

import Foundation
import Testing
@testable import SimpleMediaPlayer

struct MusicAnalysisDeferralTests {
    @Test func cachedAnalysisReturnsWithoutWaitingOrReading() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let fixture = try AnalysisDeferralFixture()
        defer { fixture.cleanup() }
        MusicAnalysisCache.write(MusicAnalysis(duration: 8, bpm: 128), at: try fixture.entryURL())
        let events = EventRecorder()
        let service = fixture.service(events: events) { events.record("wait") }

        #expect(try await service.analyze(url: fixture.url).bpm == 128)
        #expect(events.values.isEmpty)
    }

    @Test func uncachedAnalysisWaitsBeforeOpeningTheFile() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let fixture = try AnalysisDeferralFixture()
        defer { fixture.cleanup() }
        let events = EventRecorder()
        let service = fixture.service(events: events) { events.record("wait") }

        await #expect(throws: CocoaError.self) { try await service.analyze(url: fixture.url) }
        #expect(events.values == ["wait", "read"])
    }

    @Test func cancellationDuringTheWaitSkipsTheFileAndTheCache() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let fixture = try AnalysisDeferralFixture()
        defer { fixture.cleanup() }
        let events = EventRecorder()
        let entered = DispatchSemaphore(value: 0)
        let service = fixture.service(events: events) {
            events.record("wait")
            entered.signal()
            try await Task.sleep(for: .seconds(60))
        }
        let task = Task { try await service.analyze(url: fixture.url) }
        try #require(await entered.waitAsync(timeout: .now() + 5) == .success)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(events.values == ["wait"])
        #expect(!FileManager.default.fileExists(atPath: try fixture.entryURL().path))
    }

    // The wait ignores cancellation here, so only the check after it keeps the switched-away track from reading.
    @MainActor
    @Test func resetDuringANoncooperativeWaitSkipsTheFileAndLeavesTheControllerIdle() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let fixture = try AnalysisDeferralFixture()
        defer { fixture.cleanup() }
        let events = EventRecorder()
        let gate = WaitGate()
        let service = fixture.service(events: events) {
            events.record("wait")
            await gate.wait()
        }
        let controller = MusicAnalysisController(analyzeWithProgress: { url, progress in
            try await service.analyze(url: url, onProgress: progress)
        })
        let task = controller.load(url: fixture.url)
        defer { gate.release() }
        try #require(await gate.waitUntilEntered())

        controller.reset()
        gate.release()
        await task?.value
        #expect(events.values == ["wait"])
        #expect(controller.status == .idle)
        #expect(controller.result == nil)
        #expect(!FileManager.default.fileExists(atPath: try fixture.entryURL().path))
    }
}

private struct AnalysisDeferralFixture {
    let directory: URL
    let cache: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicAnalysisDeferralTests-\(UUID().uuidString)", isDirectory: true)
        cache = directory.appendingPathComponent("cache", isDirectory: true)
        url = directory.appendingPathComponent("song.flac")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tag-test.flac")
        try FileManager.default.copyItem(at: fixture, to: url)
    }

    func entryURL() throws -> URL {
        try #require(MusicAnalysisCache.entryURL(for: url, in: cache))
    }

    func service(
        events: EventRecorder, wait: @escaping @Sendable () async throws -> Void
    ) -> MusicAnalysisService {
        MusicAnalysisService(cacheDirectory: cache, readableFile: { _ in
            events.record("read")
            throw CocoaError(.fileReadUnknown)
        }, waitBeforeAnalyzing: wait)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

nonisolated private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] { lock.withLock { events } }

    func record(_ event: String) { lock.withLock { events.append(event) } }
}

/// Holds a wait open regardless of cancellation until the test releases it.
nonisolated private final class WaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isReleased { return true }
                waiter = continuation
                return false
            }
            entered.signal()
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilEntered() async -> Bool {
        await entered.waitAsync(timeout: .now() + 5) == .success
    }

    func release() {
        let waiter = lock.withLock {
            isReleased = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }
}

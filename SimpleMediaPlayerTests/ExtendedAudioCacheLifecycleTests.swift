import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct ExtendedAudioCacheLifecycleTests {
    @Test func uiReleaseAndRemovalDoNotWaitForFilesystemValidation() async throws {
        let fixture = try CacheFixture(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        defer { fixture.cleanup() }
        let queue = DispatchQueue(label: "ExtendedAudioCacheTests.maintenance")
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000, maintenanceQueue: queue)
        let leased = try cache.acquireReadableFile(at: fixture.url("leased"), create: { temporary, _ in
            try writePlayableAudio(to: temporary)
        }, isSourceCurrent: { true })
        defer { leased.release() }
        let destination = fixture.url("validating")
        try writePlayableAudio(to: destination)
        let validation = BlockingCacheValidation()
        let worker = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: { _, _ in
                Issue.record("A cache hit must not decode")
            }, isSourceCurrent: validation.check)
        }
        defer { worker.cancel(); validation.release() }
        try #require(await validation.waitUntilStarted())
        let completed = DispatchSemaphore(value: 0)
        let uiAction = Task { @MainActor in
            leased.release()
            cache.removeInBackground(at: destination)
            completed.signal()
        }

        #expect(await completed.waitAsync(timeout: .now() + 2) == .success)
        validation.release()
        await uiAction.value
        await #expect(throws: CancellationError.self) { try await worker.value }
        await queue.drain()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(arguments: [false, true])
    func leasePreservesEntryBetweenAcquisitionAndOpen(cacheHit: Bool) async throws {
        let fixture = try CacheFixture(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        defer { fixture.cleanup() }
        let firstURL = fixture.url("first")
        if cacheHit { try writePlayableAudio(to: firstURL) }
        let queue = DispatchQueue(label: "ExtendedAudioCacheTests.maintenance")
        let cache = ExtendedAudioCache(maximumBytes: 1, maintenanceQueue: queue)
        let first = try await Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: firstURL, create: { temporary, _ in
                #expect(!cacheHit)
                try writePlayableAudio(to: temporary)
            }, isSourceCurrent: { true })
        }.value
        defer { first.release() }
        let second = try await Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: fixture.url("second"), create: { temporary, _ in
                try writePlayableAudio(to: temporary)
            }, isSourceCurrent: { true })
        }.value
        defer { second.release() }

        // A competing publication has pruned; the consumer deliberately opens afterward.
        #expect(try AVAudioFile(forReading: first.url).length > 0)
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        first.release()
        first.release()
        await queue.drain()
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        second.release()
        await queue.drain()
        #expect(try fixture.completedBytes() == 0)
    }

    @Test func oneReaderReleasingDoesNotUnpinAnotherReader() async throws {
        let fixture = try CacheFixture(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        defer { fixture.cleanup() }
        let destination = fixture.url("shared")
        try writePlayableAudio(to: destination)
        let queue = DispatchQueue(label: "ExtendedAudioCacheTests.maintenance")
        let cache = ExtendedAudioCache(maximumBytes: 1, maintenanceQueue: queue)
        let first = try cache.acquireReadableFile(at: destination, create: { _, _ in
            Issue.record("A cache hit must not decode")
        }, isSourceCurrent: { true })
        let second = try cache.acquireReadableFile(at: destination, create: { _, _ in
            Issue.record("A cache hit must not decode")
        }, isSourceCurrent: { true })
        defer { first.release(); second.release() }
        first.release()
        await queue.drain()
        #expect(try AVAudioFile(forReading: second.url).length > 0)
        second.release()
        await queue.drain()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cacheHitRemovesAbandonedPartialFiles() throws {
        let fixture = try CacheFixture(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        defer { fixture.cleanup() }
        let destination = fixture.url("cached")
        try writePlayableAudio(to: destination)
        let abandoned = fixture.directory.appendingPathComponent(".abandoned.partial.caf")
        try writePlayableAudio(to: abandoned)
        let unrelated = fixture.directory.appendingPathComponent(".unrelated.caf")
        try writePlayableAudio(to: unrelated)
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let file = try cache.acquireReadableFile(at: destination, create: { _, _ in
            Issue.record("A cache hit must not decode")
        }, isSourceCurrent: { true })
        defer { file.release() }

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try AVAudioFile(forReading: file.url).length > 0)
    }

    @Test func sourceChangeAfterMoveRejectsPublishedEntry() throws {
        let fixture = try CacheFixture(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("source-changed-after-move")
        var validationCount = 0

        #expect(throws: CancellationError.self) {
            try cache.acquireReadableFile(at: destination, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
            }, isSourceCurrent: {
                validationCount += 1
                return validationCount == 1
            })
        }
        #expect(validationCount == 2)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func invalidatedDecoderTemporaryIsPreservedUntilItFinishes() async throws {
        let fixture = try CacheFixture(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("invalidated")
        let probe = BlockingCacheDecode()
        let producer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())
        let temporary = try #require(probe.temporaryURL)
        cache.invalidate(at: destination)
        let other = try cache.acquireReadableFile(at: fixture.url("other"), create: { temporary, _ in
            try writePlayableAudio(to: temporary)
        }, isSourceCurrent: { true })
        defer { other.release() }
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        probe.release()

        await #expect(throws: CancellationError.self) { try await producer.value }
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func delayedRemovalDoesNotDeleteNewGeneration() async throws {
        let fixture = try CacheFixture(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        defer { fixture.cleanup() }
        let destination = fixture.url("reopened")
        try writePlayableAudio(to: destination)
        let queue = DispatchQueue(label: "ExtendedAudioCacheTests.maintenance")
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000, maintenanceQueue: queue)
        cache.removeInBackground(at: destination)
        let decoded = DispatchSemaphore(value: 0)
        let fresh = try await Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
                decoded.signal()
            }, isSourceCurrent: { true })
        }.value
        defer { fresh.release() }
        #expect(await decoded.waitAsync(timeout: .now()) == .success)
        queue.resume()
        suspended = false
        await queue.drain()

        #expect(try AVAudioFile(forReading: fresh.url).length > 0)
    }
}

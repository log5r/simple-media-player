import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct ExtendedAudioCacheTests {
    @Test func cachedTrackReturnsWhileAnotherTrackIsDecoding() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let decodingURL = fixture.url("decoding")
        let cachedURL = fixture.url("cached")
        try writePlayableAudio(to: cachedURL)
        let probe = BlockingCacheDecode()
        let producer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: decodingURL, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())

        let completed = DispatchSemaphore(value: 0)
        let reader = Task.detached(executorPreference: CacheTestExecutor.shared) {
            defer { completed.signal() }
            return try cache.acquireReadableFile(at: cachedURL, create: { _, _ in
                Issue.record("A playable cache entry must not be decoded again")
                throw CacheTestError.unexpectedDecode
            }, isSourceCurrent: { true })
        }
        #expect(await completed.waitAsync(timeout: .now() + 2) == .success)
        probe.release()
        #expect((try await reader.value).url == cachedURL)
        #expect((try await producer.value).url == decodingURL)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func concurrentReadersOfOneTrackDecodeOnce() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("shared")
        let probe = BlockingCacheDecode()
        let producer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())

        let entered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let duplicate = Task.detached(executorPreference: CacheTestExecutor.shared) {
            defer { completed.signal() }
            entered.signal()
            return try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        try #require(await entered.waitAsync(timeout: .now() + 2) == .success)
        #expect(await completed.waitAsync(timeout: .now() + 0.1) == .timedOut)
        probe.release()

        #expect((try await producer.value).url == destination)
        #expect((try await duplicate.value).url == destination)
        #expect(probe.createCount == 1)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func cancelledWaiterReturnsBeforeProducerCompletes() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("shared")
        let probe = BlockingCacheDecode()
        let producer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())

        let entered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let waiter = Task.detached(executorPreference: CacheTestExecutor.shared) {
            defer { completed.signal() }
            entered.signal()
            return try await cache.wakingWaitsOnCancellation {
                try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
            }
        }
        defer { waiter.cancel() }
        try #require(await entered.waitAsync(timeout: .now() + 2) == .success)
        #expect(await completed.waitAsync(timeout: .now() + 0.1) == .timedOut)
        waiter.cancel()
        #expect(await completed.waitAsync(timeout: .now() + 2) == .success)
        #expect(probe.createCount == 1)
        probe.release()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect((try await producer.value).url == destination)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func cancelledProducerLetsCurrentWaiterRetryDecode() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("retried")
        let probe = BlockingCacheDecode()
        let producer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())

        let entered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let waiter = Task.detached(executorPreference: CacheTestExecutor.shared) {
            defer { completed.signal() }
            entered.signal()
            return try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { waiter.cancel(); probe.release() }
        try #require(await entered.waitAsync(timeout: .now() + 2) == .success)
        #expect(await completed.waitAsync(timeout: .now() + 0.1) == .timedOut)
        producer.cancel()
        probe.release()

        await #expect(throws: CancellationError.self) { try await producer.value }
        try #require(await probe.waitUntilStarted())
        #expect(probe.createCount == 2)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        probe.release()
        #expect((try await waiter.value).url == destination)
        #expect(try AVAudioFile(forReading: destination).length > 0)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test(arguments: CacheInvalidation.allCases)
    private func invalidationDuringDecodeRejectsPublication(_ invalidation: CacheInvalidation) async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("invalidated")
        let probe = BlockingCacheDecode()
        let producer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())

        switch invalidation {
        case .invalidate: cache.invalidate(at: destination)
        case .remove: cache.remove(at: destination)
        }
        probe.release()

        await #expect(throws: CancellationError.self) { try await producer.value }
        #expect(probe.observedCancellation)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func terminalDecodeFailureDoesNotCachePlayablePartialOutput() throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("failed")

        #expect(throws: CacheTestError.terminalDecodeFailure) {
            try cache.acquireReadableFile(at: destination, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
                #expect(try AVAudioFile(forReading: temporary).length > 0)
                throw CacheTestError.terminalDecodeFailure
            }, isSourceCurrent: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fixture.partialFiles().isEmpty)

        #expect(try cache.acquireReadableFile(at: destination, create: { temporary, _ in
            try writePlayableAudio(to: temporary)
        }, isSourceCurrent: { true }).url == destination)
        #expect(try AVAudioFile(forReading: destination).length > 0)
    }

    @Test func pruningBoundsCompletedBytesAndPreservesInFlightTemporaryFiles() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let oldest = fixture.url("oldest")
        let newer = fixture.url("newer")
        try writePlayableAudio(to: oldest)
        try writePlayableAudio(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: newer.path
        )
        let size = try #require(oldest.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let capacity = Int64(size * 2)
        let cache = ExtendedAudioCache(maximumBytes: capacity)
        let pendingURL = fixture.url("pending")
        let probe = BlockingCacheDecode()
        let pending = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: pendingURL, create: probe.create, isSourceCurrent: { true })
        }
        defer { pending.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())
        let temporary = try #require(probe.temporaryURL)
        let abandoned = fixture.directory.appendingPathComponent(".abandoned.partial.caf")
        try writePlayableAudio(to: abandoned)
        let completedURL = fixture.url("completed")

        let completed = DispatchSemaphore(value: 0)
        let writer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            defer { completed.signal() }
            return try cache.acquireReadableFile(at: completedURL, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
            }, isSourceCurrent: { true })
        }
        let finishedWhileDecodeWasBlocked = await completed.waitAsync(timeout: .now() + 2) == .success
        #expect(finishedWhileDecodeWasBlocked)
        if !finishedWhileDecodeWasBlocked {
            // Release even after a regression so the test cannot strand either task.
            probe.release()
        }
        #expect((try await writer.value).url == completedURL)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: newer.path))
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try fixture.completedBytes() <= capacity)
        probe.release()
        #expect((try await pending.value).url == pendingURL)
        #expect(FileManager.default.fileExists(atPath: completedURL.path))
        #expect(try fixture.completedBytes() <= capacity)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func changedSourceIdentityRejectsPublication() throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("changed-source")

        #expect(throws: CancellationError.self) {
            try cache.acquireReadableFile(at: destination, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
            }, isSourceCurrent: { false })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fixture.partialFiles().isEmpty)
    }
}

extension ExtendedAudioCacheTests {
    // A waiter outside the waking scope has no cancellation wakeup, so this shows that the wait does not poll.
    @Test func cancelledWaiterWithoutWakingScopeSleepsUntilDecodeFinishes() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("unpolled")
        let probe = BlockingCacheDecode()
        let producer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())

        let entered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let waiter = Task.detached(executorPreference: CacheTestExecutor.shared) {
            defer { completed.signal() }
            entered.signal()
            return try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { waiter.cancel() }
        try #require(await entered.waitAsync(timeout: .now() + 2) == .success)
        // Cancel only after the waiter has had time to reach the wait; a waiter cancelled earlier never waits.
        #expect(await completed.waitAsync(timeout: .now() + 0.1) == .timedOut)
        waiter.cancel()
        // The previous implementation woke every 50 ms and returned here.
        #expect(await completed.waitAsync(timeout: .now() + 0.5) == .timedOut)
        probe.release()

        #expect(await completed.waitAsync(timeout: .now() + 2) == .success)
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect((try await producer.value).url == destination)
        #expect(probe.createCount == 1)
    }

    @Test func waiterCancelledBeforeEnteringWakingScopeDoesNotWait() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("cancelled-first")
        let probe = BlockingCacheDecode()
        let producer = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(await probe.waitUntilStarted())

        let completed = DispatchSemaphore(value: 0)
        let waiter = Task.detached(executorPreference: CacheTestExecutor.shared) {
            defer { completed.signal() }
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.wakingWaitsOnCancellation {
                try cache.acquireReadableFile(at: destination, create: probe.create, isSourceCurrent: { true })
            }
        }
        #expect(await completed.waitAsync(timeout: .now() + 2) == .success)
        await #expect(throws: CancellationError.self) { try await waiter.value }
        probe.release()
        #expect((try await producer.value).url == destination)
        #expect(probe.createCount == 1)
    }

    @Test func cancellationDuringSourceValidationRejectsPublication() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("cancelled-source-validation")
        let task = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
            }, isSourceCurrent: {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            })
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test(arguments: CacheHitInvalidity.allCases)
    private func cachedEntryChecksSourceIdentityAndCancellation(_ invalidity: CacheHitInvalidity) async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("cached-source-validation")
        try writePlayableAudio(to: destination)
        let task = Task.detached(executorPreference: CacheTestExecutor.shared) {
            try cache.acquireReadableFile(at: destination, create: { _, _ in
                Issue.record("A source-invalid cache hit must not start decoding")
                throw CacheTestError.unexpectedDecode
            }, isSourceCurrent: {
                switch invalidity {
                case .changedSource: return false
                case .cancelledTask:
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }
            })
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try AVAudioFile(forReading: destination).length > 0)
        #expect(try fixture.partialFiles().isEmpty)
    }
}

private enum CacheTestError: Error, Equatable {
    case unexpectedDecode
    case terminalDecodeFailure
}

private enum CacheInvalidation: CaseIterable {
    case invalidate
    case remove
}

private enum CacheHitInvalidity: CaseIterable, Sendable {
    case changedSource
    case cancelledTask
}

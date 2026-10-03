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
        let producer = Task.detached {
            try cache.readableURL(at: decodingURL, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(probe.waitUntilStarted())

        let completed = DispatchSemaphore(value: 0)
        let reader = Task.detached {
            defer { completed.signal() }
            return try cache.readableURL(at: cachedURL, create: { _, _ in
                Issue.record("A playable cache entry must not be decoded again")
                throw CacheTestError.unexpectedDecode
            }, isSourceCurrent: { true })
        }
        #expect(completed.wait(timeout: .now() + 2) == .success)
        probe.release()
        #expect(try await reader.value == cachedURL)
        #expect(try await producer.value == decodingURL)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func concurrentReadersOfOneTrackDecodeOnce() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("shared")
        let probe = BlockingCacheDecode()
        let producer = Task.detached {
            try cache.readableURL(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(probe.waitUntilStarted())

        let entered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let duplicate = Task.detached {
            defer { completed.signal() }
            entered.signal()
            return try cache.readableURL(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        #expect(completed.wait(timeout: .now() + 0.1) == .timedOut)
        probe.release()

        #expect(try await producer.value == destination)
        #expect(try await duplicate.value == destination)
        #expect(probe.createCount == 1)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func cancelledWaiterReturnsBeforeProducerCompletes() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("shared")
        let probe = BlockingCacheDecode()
        let producer = Task.detached {
            try cache.readableURL(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(probe.waitUntilStarted())

        let entered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let waiter = Task.detached {
            defer { completed.signal() }
            entered.signal()
            return try cache.readableURL(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { waiter.cancel() }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        #expect(completed.wait(timeout: .now() + 0.1) == .timedOut)
        waiter.cancel()
        #expect(completed.wait(timeout: .now() + 2) == .success)
        #expect(probe.createCount == 1)
        probe.release()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(try await producer.value == destination)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test func cancelledProducerLetsCurrentWaiterRetryDecode() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("retried")
        let probe = BlockingCacheDecode()
        let producer = Task.detached {
            try cache.readableURL(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(probe.waitUntilStarted())

        let entered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let waiter = Task.detached {
            defer { completed.signal() }
            entered.signal()
            return try cache.readableURL(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { waiter.cancel(); probe.release() }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        #expect(completed.wait(timeout: .now() + 0.1) == .timedOut)
        producer.cancel()
        probe.release()

        await #expect(throws: CancellationError.self) { try await producer.value }
        try #require(probe.waitUntilStarted())
        #expect(probe.createCount == 2)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        probe.release()
        #expect(try await waiter.value == destination)
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
        let producer = Task.detached {
            try cache.readableURL(at: destination, create: probe.create, isSourceCurrent: { true })
        }
        defer { producer.cancel(); probe.release() }
        try #require(probe.waitUntilStarted())

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
            try cache.readableURL(at: destination, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
                #expect(try AVAudioFile(forReading: temporary).length > 0)
                throw CacheTestError.terminalDecodeFailure
            }, isSourceCurrent: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fixture.partialFiles().isEmpty)

        #expect(try cache.readableURL(at: destination, create: { temporary, _ in
            try writePlayableAudio(to: temporary)
        }, isSourceCurrent: { true }) == destination)
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
        let pending = Task.detached {
            try cache.readableURL(at: pendingURL, create: probe.create, isSourceCurrent: { true })
        }
        defer { pending.cancel(); probe.release() }
        try #require(probe.waitUntilStarted())
        let temporary = try #require(probe.temporaryURL)
        let completedURL = fixture.url("completed")

        let completed = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            defer { completed.signal() }
            return try cache.readableURL(at: completedURL, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
            }, isSourceCurrent: { true })
        }
        let finishedWhileDecodeWasBlocked = completed.wait(timeout: .now() + 2) == .success
        #expect(finishedWhileDecodeWasBlocked)
        if !finishedWhileDecodeWasBlocked {
            // Release even after a regression so the test cannot strand either task.
            probe.release()
        }
        #expect(try await writer.value == completedURL)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: newer.path))
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(try fixture.completedBytes() <= capacity)
        probe.release()
        #expect(try await pending.value == pendingURL)
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
            try cache.readableURL(at: destination, create: { temporary, _ in
                try writePlayableAudio(to: temporary)
            }, isSourceCurrent: { false })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fixture.partialFiles().isEmpty)
    }
}

extension ExtendedAudioCacheTests {
    @Test func cancellationDuringSourceValidationRejectsPublication() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = ExtendedAudioCache(maximumBytes: 1_000_000)
        let destination = fixture.url("cancelled-source-validation")
        let task = Task.detached {
            try cache.readableURL(at: destination, create: { temporary, _ in
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
        let task = Task.detached {
            try cache.readableURL(at: destination, create: { _, _ in
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

private struct CacheFixture: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).caf") }

    func partialFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "caf" }
    }

    func completedBytes() throws -> Int64 {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "caf" }
            .reduce(0) { total, url in
                total + Int64(try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
            }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class BlockingCacheDecode: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var temporary: URL?
    private var cancelled = false

    var createCount: Int { lock.withLock { calls } }
    var temporaryURL: URL? { lock.withLock { temporary } }
    var observedCancellation: Bool { lock.withLock { cancelled } }

    func create(_ url: URL, shouldCancel: @escaping @Sendable () -> Bool) throws {
        try writePlayableAudio(to: url)
        lock.withLock {
            calls += 1
            temporary = url
        }
        started.signal()
        guard gate.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        lock.withLock { cancelled = shouldCancel() }
        // Return playable output even when cancelled to exercise the publication check.
    }

    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 2) == .success }
    func release() { gate.signal() }
}

private func writePlayableAudio(to url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
    buffer.frameLength = buffer.frameCapacity
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

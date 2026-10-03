import AVFoundation
import Foundation
import Testing

nonisolated struct CacheFixture: Sendable {
    let directory: URL

    init(baseDirectory: URL = FileManager.default.temporaryDirectory) throws {
        directory = baseDirectory.appendingPathComponent(UUID().uuidString)
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

nonisolated final class BlockingCacheDecode: @unchecked Sendable {
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

    func waitUntilStarted() async -> Bool { await started.waitAsync(timeout: .now() + 10) == .success }
    func release() { gate.signal() }
}

nonisolated final class BlockingCacheValidation: Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    func check() throws -> Bool {
        started.signal()
        guard gate.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        return true
    }

    func waitUntilStarted() async -> Bool { await started.waitAsync(timeout: .now() + 10) == .success }
    func release() { gate.signal() }
}

nonisolated func writePlayableAudio(to url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
    buffer.frameLength = buffer.frameCapacity
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

// Blocking cache/decoder calls keep task cancellation while using GCD workers.
nonisolated final class CacheTestExecutor: TaskExecutor {
    static let shared = CacheTestExecutor()
    private let queue = DispatchQueue(label: "ExtendedAudioCacheTests.workers", attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

extension DispatchSemaphore {
    nonisolated func waitAsync(timeout: DispatchTime) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.wait(timeout: timeout)) }
        }
    }
}

extension DispatchQueue {
    nonisolated func drain() async {
        await withCheckedContinuation { continuation in
            async { continuation.resume() }
        }
    }
}

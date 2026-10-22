import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct BookmarkFixture {
    let directory: URL
    let mediaDirectory: URL
    let container: ModelContainer
    let service: LibraryService
    let journal: PendingFileRemovalJournal
    private let journalSuiteName = "LibraryBookmarkResolutionTests-\(UUID().uuidString)"
    var context: ModelContext { container.mainContext }

    init(recorder: BookmarkResolutionRecorder) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        mediaDirectory = directory.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        journal = PendingFileRemovalJournal(defaults: try #require(UserDefaults(suiteName: journalSuiteName)))
        service = LibraryService(
            mediaDirectoryURL: mediaDirectory, resolveBookmark: recorder.resolve, removalJournal: journal
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: journalSuiteName)?.removePersistentDomain(forName: journalSuiteName)
    }

    func makeAudio(named name: String, frameCount: AVAudioFrameCount) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        samples.update(repeating: 0.1, count: Int(frameCount))
        try file.write(from: buffer)
        return url
    }

    /// Inserts an item without a fingerprint, like one imported before fingerprints were recorded.
    func insertItem(copying source: URL) throws -> MediaItem {
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        try FileManager.default.copyItem(at: source, to: mediaDirectory.appendingPathComponent(fileName))
        let item = MediaItem(
            id: id, title: "Track", duration: 0.1, isVideo: false, bookmarkData: Data([0xFF]), fileName: fileName
        )
        context.insert(item)
        try context.save()
        return item
    }
}

/// Blocked resolutions occupy cooperative threads, so tests wait for them with continuations resumed by the
/// resolving thread instead of `Task.sleep`, whose wake-up needs a free cooperative thread.
nonisolated final class BookmarkResolutionRecorder: @unchecked Sendable {
    struct WaitTimeout: Error {}
    private struct Waiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct Resolution {
        let call: Int
        let gate: DispatchSemaphore?
        let ready: [Waiter]
    }

    private let blockTimeout: DispatchTimeInterval
    private let reportTimeout: @Sendable () -> Void
    private let lock = NSLock()
    private let blocks: @Sendable (Int) -> Bool
    private var counts = (mainThread: 0, worker: 0)
    private var gates: [Int: DispatchSemaphore] = [:]
    private var releasedCalls: Set<Int> = []
    private var isReleased = false
    private var waiters: [Waiter] = []

    /// Blocks each resolution whose 1-based call number satisfies `blocks` until it is released.
    init(
        blockTimeout: DispatchTimeInterval = .seconds(30),
        reportTimeout: @escaping @Sendable () -> Void = { Issue.record("A blocked bookmark resolution timed out") },
        blocking blocks: @escaping @Sendable (Int) -> Bool = { _ in false }
    ) {
        self.blockTimeout = blockTimeout
        self.reportTimeout = reportTimeout
        self.blocks = blocks
    }

    var mainThreadCount: Int { lock.withLock { counts.mainThread } }
    var workerCount: Int { lock.withLock { counts.worker } }
    var blockedCallCount: Int { lock.withLock { gates.count } }

    func waitForCalls(_ count: Int, timeout: DispatchTimeInterval = .seconds(10)) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let isReady = lock.withLock {
                guard counts.mainThread + counts.worker < count else { return true }
                waiters.append(Waiter(id: id, count: count, continuation: continuation))
                return false
            }
            if isReady {
                continuation.resume()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    let expired = lock.withLock {
                        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil as Waiter? }
                        return waiters.remove(at: index)
                    }
                    expired?.continuation.resume(throwing: WaitTimeout())
                }
            }
        }
    }

    func resolve(_ bookmarkData: Data, _ fallbackURL: URL) -> URL {
        let resolution = lock.withLock { () -> Resolution in
            if Thread.isMainThread { counts.mainThread += 1 } else { counts.worker += 1 }
            let call = counts.mainThread + counts.worker
            let ready = waiters.filter { $0.count <= call }
            waiters.removeAll { $0.count <= call }
            guard blocks(call), isReleased == false, releasedCalls.contains(call) == false else {
                return Resolution(call: call, gate: nil, ready: ready)
            }
            let gate = DispatchSemaphore(value: 0)
            gates[call] = gate
            return Resolution(call: call, gate: gate, ready: ready)
        }
        resolution.ready.forEach { $0.continuation.resume() }
        if let gate = resolution.gate {
            let result = gate.wait(timeout: .now() + blockTimeout)
            _ = lock.withLock { gates.removeValue(forKey: resolution.call) }
            if result == .timedOut { reportTimeout() }
        }
        return fallbackURL
    }

    func release(call: Int) {
        let gate = lock.withLock {
            releasedCalls.insert(call)
            return gates.removeValue(forKey: call)
        }
        gate?.signal()
    }

    func release() {
        let pending = lock.withLock {
            isReleased = true
            defer { gates = [:] }
            return Array(gates.values)
        }
        pending.forEach { $0.signal() }
    }
}

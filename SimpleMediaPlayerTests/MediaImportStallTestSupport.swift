import Foundation
@testable import SimpleMediaPlayer

/// Reads one file in chunks, checking for cancellation between them like `MediaImportFingerprint.read`,
/// and pauses after a chunk until the reading task is cancelled. Other files are read normally, and the
/// probe records how far the paused read had got when one of them started.
nonisolated final class ChunkedFingerprintProbe: @unchecked Sendable {
    enum ReadState: Equatable { case notStarted, reading, stopped, finished }

    let chunkCount: Int
    private let heldFileName: String
    private let pausedChunk: Int
    private let lock = NSLock()
    private var state = ReadState.notStarted
    private var readChunks = 0
    private var statesWhenOthersStarted: [ReadState] = []
    private var outcome: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    init(heldFileName: String, chunkCount: Int = 8, pausedChunk: Int = 2) {
        self.heldFileName = heldFileName
        self.chunkCount = chunkCount
        self.pausedChunk = pausedChunk
    }

    var chunksRead: Int { lock.withLock { readChunks } }
    var heldReadState: ReadState { lock.withLock { state } }
    var heldStatesWhenOtherReadsStarted: [ReadState] { lock.withLock { statesWhenOthersStarted } }

    func read(from url: URL) throws -> String {
        guard url.lastPathComponent == heldFileName else {
            lock.withLock { statesWhenOthersStarted.append(state) }
            return try MediaImportFingerprint.read(from: url)
        }
        lock.withLock { state = .reading }
        do {
            for chunk in 1...chunkCount {
                try Task.checkCancellation()
                lock.withLock { readChunks += 1 }
                if chunk == pausedChunk { pauseUntilCancelled() }
            }
        } catch {
            lock.withLock { state = .stopped }
            throw error
        }
        lock.withLock { state = .finished }
        return try MediaImportFingerprint.read(from: url)
    }

    /// Lets a test that waits for the pause stop when the import ends without reaching it.
    func taskEnded() { finishWaiting(paused: false) }

    /// Returns true once the read is paused, or false when the import ended first.
    func waitUntilPaused() async -> Bool {
        await withCheckedContinuation { continuation in
            let outcome: Bool? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let outcome { continuation.resume(returning: outcome) }
        }
    }

    /// Runs in the detached reading task. It waits only for that task's cancellation, with a bound, so a
    /// read the cancellation does not reach resumes after the bound and reads to the end.
    private func pauseUntilCancelled() {
        finishWaiting(paused: true)
        let deadline = Date().addingTimeInterval(10)
        while Task.isCancelled == false, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func finishWaiting(paused: Bool) {
        let waiter: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = paused
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: paused)
    }
}

/// Stalls every call on a `FileSystemWorkQueue` worker, as a stalled file provider would, until released,
/// and records how many calls entered and how many ran at once.
nonisolated final class StalledFileOperationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isReleased = false
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var entryCount = 0
    private var waiters: [EntryWaiter] = []

    private struct EntryWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    var entries: Int { condition.withLock { entryCount } }
    var maximumActive: Int { condition.withLock { maximumActiveCount } }
    var active: Int { condition.withLock { activeCount } }

    func stall() {
        let ready = condition.withLock {
            entryCount += 1
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            let ready = waiters.filter { $0.count <= entryCount }
            waiters.removeAll { $0.count <= entryCount }
            return ready
        }
        ready.forEach { $0.continuation.resume(returning: true) }
        condition.withLock {
            let deadline = Date().addingTimeInterval(10)
            while isReleased == false, condition.wait(until: deadline) {}
            activeCount -= 1
            condition.broadcast()
        }
    }

    /// Returns true once `count` calls have entered, or false after `timeout` seconds.
    func waitForEntries(_ count: Int, timeout: TimeInterval) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let entered = condition.withLock {
                if entryCount >= count { return true }
                waiters.append(EntryWaiter(id: id, count: count, continuation: continuation))
                return false
            }
            if entered {
                continuation.resume(returning: true)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                let expired = condition.withLock { () -> CheckedContinuation<Bool, Never>? in
                    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return waiters.remove(at: index).continuation
                }
                expired?.resume(returning: false)
            }
        }
    }

    /// Lets every stalled and later call finish; returns once no call is stalled, or after a bound.
    func release() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
            let deadline = Date().addingTimeInterval(10)
            while activeCount > 0, condition.wait(until: deadline) {}
        }
    }
}

/// Copies one file in chunks, checking `shouldStop` between them like `ManagedFileCopier`, and pauses after a
/// chunk until `shouldStop` returns true. Other files are copied by `ManagedFileCopier`.
nonisolated final class ChunkedCopyProbe: @unchecked Sendable {
    enum CopyState: Equatable { case notStarted, copying, stopped, finished }

    let chunkCount: Int
    private let heldFileName: String
    private let pausedChunk: Int
    private let lock = NSLock()
    private var state = CopyState.notStarted
    private var writtenChunks = 0
    private var outcome: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    init(heldFileName: String, chunkCount: Int = 8, pausedChunk: Int = 2) {
        self.heldFileName = heldFileName
        self.chunkCount = chunkCount
        self.pausedChunk = pausedChunk
    }

    var chunksWritten: Int { lock.withLock { writtenChunks } }
    var heldCopyState: CopyState { lock.withLock { state } }

    func copy(from source: URL, to destination: URL, shouldStop: @escaping @Sendable () -> Bool) throws {
        guard source.lastPathComponent == heldFileName else {
            try ManagedFileCopier.copy(from: source, to: destination, shouldStop: shouldStop)
            return
        }
        lock.withLock { state = .copying }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        for chunk in 1...chunkCount {
            guard shouldStop() == false else {
                lock.withLock { state = .stopped }
                throw CancellationError()
            }
            try handle.write(contentsOf: Data(repeating: 0x5A, count: 1_024))
            lock.withLock { writtenChunks += 1 }
            if chunk == pausedChunk { pause(until: shouldStop) }
        }
        try handle.close()
        try FileManager.default.removeItem(at: destination)
        try ManagedFileCopier.copy(from: source, to: destination) { false }
        lock.withLock { state = .finished }
    }

    func taskEnded() { finishWaiting(paused: false) }

    /// Returns true once the copy is paused, or false when the import ended first.
    func waitUntilPaused() async -> Bool {
        await withCheckedContinuation { continuation in
            let outcome: Bool? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let outcome { continuation.resume(returning: outcome) }
        }
    }

    /// Runs on a `FileSystemWorkQueue` worker, not a cooperative thread, and waits at most 10 seconds.
    private func pause(until shouldStop: () -> Bool) {
        finishWaiting(paused: true)
        let deadline = Date().addingTimeInterval(10)
        while shouldStop() == false, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func finishWaiting(paused: Bool) {
        let waiter: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = paused
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: paused)
    }
}

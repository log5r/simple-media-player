import Foundation

/// Runs blocking file system work, such as bookmark resolution on a slow volume, on a dispatch queue so it
/// does not hold one of Swift's cooperative threads while it waits.
nonisolated enum FileSystemWorkQueue {
    private static let queue = DispatchQueue(
        label: "SimpleMediaPlayer.FileSystemWork", qos: .utility, attributes: .concurrent
    )

    static func run<T: Sendable>(
        qos: DispatchQoS = .utility, _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async(qos: qos, flags: .enforceQoS) { continuation.resume(returning: work()) }
        }
    }

    /// Returns as soon as the caller is cancelled. The synchronous work cannot be interrupted, so it finishes
    /// on the queue and its result is discarded.
    ///
    /// With a `limiter`, the work starts only after taking one of its slots and gives the slot back when the
    /// work itself finishes, not when the caller stops waiting. Abandoned work therefore keeps counting
    /// against the limit, and repeated cancel-and-retry cycles cannot pile up blocked work on the queue.
    static func runCancellable<T: Sendable>(
        qos: DispatchQoS = .utility, limiter: FileSystemWorkLimiter? = nil, _ work: @escaping @Sendable () -> T
    ) async throws -> T {
        try await limiter?.acquire()
        let resumption = Resumption<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard resumption.install(continuation) else {
                    limiter?.release()
                    return
                }
                queue.async(qos: qos, flags: .enforceQoS) {
                    let result = work()
                    limiter?.release()
                    resumption.resume(with: .success(result))
                }
            }
        } onCancel: {
            resumption.resume(with: .failure(CancellationError()))
        }
    }
}

/// Bounds how much file system work runs at once, counting work whose caller has stopped waiting.
nonisolated final class FileSystemWorkLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    /// Waits for a free slot. A cancelled caller stops waiting without taking one.
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let acquired: Bool? = lock.withLock {
                    // The cancellation handler may have run before the waiter was registered.
                    if Task.isCancelled { return nil }
                    if running < limit {
                        running += 1
                        return true
                    }
                    waiters.append((id, continuation))
                    return false
                }
                switch acquired {
                case nil: continuation.resume(throwing: CancellationError())
                case true?: continuation.resume()
                case false?: break
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Hands the slot to the oldest waiter, or frees it.
    func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard waiters.isEmpty == false else {
                running -= 1
                return nil
            }
            return waiters.removeFirst().continuation
        }
        next?.resume()
    }
}

/// Resumes a continuation once, whichever of the work and the cancellation finishes first.
private nonisolated final class Resumption<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var isCancelled = false

    /// Returns false when cancellation arrived first; the continuation has then been resumed already.
    func install(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        let wasCancelled = lock.withLock {
            if isCancelled { return true }
            self.continuation = continuation
            return false
        }
        if wasCancelled { continuation.resume(throwing: CancellationError()) }
        return wasCancelled == false
    }

    func resume(with result: Result<T, any Error>) {
        let continuation = lock.withLock {
            if case .failure = result { isCancelled = true }
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

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
    static func runCancellable<T: Sendable>(
        qos: DispatchQoS = .utility, _ work: @escaping @Sendable () -> T
    ) async throws -> T {
        let resumption = Resumption<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard resumption.install(continuation) else { return }
                queue.async(qos: qos, flags: .enforceQoS) { resumption.resume(with: .success(work())) }
            }
        } onCancel: {
            resumption.resume(with: .failure(CancellationError()))
        }
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

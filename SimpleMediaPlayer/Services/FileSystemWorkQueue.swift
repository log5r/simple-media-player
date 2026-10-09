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
}

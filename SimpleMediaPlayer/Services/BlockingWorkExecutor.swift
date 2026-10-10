import Dispatch

/// Runs tasks whose work blocks a thread, such as reading or decoding a whole audio file, on dispatch worker
/// threads instead of Swift's small cooperative pool. Start them with
/// `Task.detached(executorPreference: BlockingWorkExecutor.shared, ...)`; task cancellation and priority
/// still apply inside the work.
nonisolated final class BlockingWorkExecutor: TaskExecutor {
    static let shared = BlockingWorkExecutor()
    private let queue = DispatchQueue(label: "SimpleMediaPlayer.BlockingWork", attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let qosClass = DispatchQoS.QoSClass(rawValue: qos_class_t(rawValue: UInt32(job.priority.rawValue)))
        let job = UnownedJob(job)
        queue.async(qos: DispatchQoS(qosClass: qosClass ?? .default, relativePriority: 0)) {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

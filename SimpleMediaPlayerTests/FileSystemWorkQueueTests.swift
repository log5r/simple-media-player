import Foundation
import Testing
@testable import SimpleMediaPlayer

struct FileSystemWorkQueueTests {
    @Test func cancellableFileSystemWorkReturnsBeforeTheWorkFinishes() async throws {
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try await FileSystemWorkQueue.runCancellable {
                started.signal()
                gate.wait()
                finished.signal()
                return 1
            }
        }
        #expect(started.wait(timeout: .now() + 10) == .success)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        gate.signal()
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(try await FileSystemWorkQueue.runCancellable { 2 } == 2)
    }

    @Test func alreadyCancelledFileSystemWorkDoesNotRun() async throws {
        let ran = DispatchSemaphore(value: 0)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileSystemWorkQueue.runCancellable { ran.signal() }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ran.wait(timeout: .now() + 0.5) == .timedOut)
    }
}

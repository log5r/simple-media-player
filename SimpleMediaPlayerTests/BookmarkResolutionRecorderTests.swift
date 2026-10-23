import Foundation
import Synchronization
import Testing

struct BookmarkResolutionRecorderTests {
    @Test func anUnreleasedResolutionReportsItsTimeout() {
        let reports = Mutex(0)
        let recorder = BookmarkResolutionRecorder(
            blockTimeout: .milliseconds(1), reportTimeout: { reports.withLock { $0 += 1 } }, blocking: { _ in true }
        )
        let url = URL(fileURLWithPath: "/unused-bookmark-test")

        #expect(recorder.resolve(Data(), url) == url)

        #expect(reports.withLock { $0 } == 1)
        #expect(recorder.blockedCallCount == 0)
    }

    @Test func missingCallsThrowAtTheDeadlineAndDoNotResumeAgain() async throws {
        let recorder = BookmarkResolutionRecorder()

        await #expect(throws: BookmarkResolutionRecorder.WaitTimeout.self) {
            try await recorder.waitForCalls(1, timeout: .milliseconds(10))
        }
        // A resolution after expiry must not resume the expired continuation a second time.
        _ = recorder.resolve(Data(), URL(fileURLWithPath: "/unused-bookmark-test"))
        try await recorder.waitForCalls(1, timeout: .milliseconds(10))
    }
}

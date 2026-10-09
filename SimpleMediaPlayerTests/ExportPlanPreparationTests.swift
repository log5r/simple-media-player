import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct ExportPlanPreparationTests {
    @Test func preparationReportsProgressAndDeliversThePlan() async throws {
        // Calls 3 and later block, so only the first two items can complete.
        let recorder = BookmarkResolutionRecorder { $0 >= 3 }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        defer { recorder.release() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        var items: [MediaItem] = []
        for _ in 0..<6 { items.append(try fixture.insertItem(copying: source)) }

        let preparation = fixture.service.beginExportPlanPreparation(for: items)

        #expect(fixture.service.exportPlanPreparation === preparation)
        #expect(preparation.totalCount == 6)
        #expect(await waitUntil { preparation.completedCount == 2 })
        #expect(preparation.fractionCompleted == 2.0 / 6.0)

        recorder.release()
        let plan = try #require(await fixture.service.exportPlan(from: preparation))

        #expect(plan.files.map(\.id) == items.map(\.id))
        #expect(preparation.completedCount == 6)
        #expect(fixture.service.exportPlanPreparation == nil)
    }

    @Test func cancelClearsThePanelAtOnceAndDiscardsThePlan() async throws {
        let recorder = BookmarkResolutionRecorder { _ in true }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        defer { recorder.release() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        var items: [MediaItem] = []
        for _ in 0..<(LibraryService.exportPlanConcurrency * 5) {
            items.append(try fixture.insertItem(copying: source))
        }
        let preparation = fixture.service.beginExportPlanPreparation(for: items)
        await recorder.waitForCalls(1)

        fixture.service.cancelExportPlanPreparation()

        #expect(fixture.service.exportPlanPreparation == nil)
        // The resolution stays blocked, so only the cancellation can end the wait.
        let start = ContinuousClock.now
        #expect(await fixture.service.exportPlan(from: preparation) == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(recorder.workerCount <= LibraryService.exportPlanConcurrency * 2)
    }

    @Test func planFinishedBeforeTheCancellationIsStillDiscarded() async throws {
        let recorder = BookmarkResolutionRecorder()
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let items = [try fixture.insertItem(copying: source)]
        let preparation = fixture.service.beginExportPlanPreparation(for: items)
        _ = try await #require(preparation.task).value

        fixture.service.cancelExportPlanPreparation()

        #expect(await fixture.service.exportPlan(from: preparation) == nil)
        #expect(fixture.service.exportPlanPreparation == nil)
    }

    @Test func replacedPreparationDoesNotClearOrDeliverForTheNewOne() async throws {
        // Only the first preparation's resolution blocks.
        let recorder = BookmarkResolutionRecorder { $0 == 1 }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        defer { recorder.release() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let first = [try fixture.insertItem(copying: source)]
        let second = [try fixture.insertItem(copying: source)]
        let old = fixture.service.beginExportPlanPreparation(for: first)
        await recorder.waitForCalls(1)

        let new = fixture.service.beginExportPlanPreparation(for: second)

        #expect(await fixture.service.exportPlan(from: old) == nil)
        #expect(fixture.service.exportPlanPreparation === new)
        #expect(old.completedCount == 0)
        let plan = try #require(await fixture.service.exportPlan(from: new))
        #expect(plan.files.map(\.id) == second.map(\.id))
        #expect(fixture.service.exportPlanPreparation == nil)
    }

    @Test func cancellingTheWaitingTaskDiscardsThePlan() async throws {
        let recorder = BookmarkResolutionRecorder { _ in true }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        defer { recorder.release() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let items = [try fixture.insertItem(copying: source)]
        let preparation = fixture.service.beginExportPlanPreparation(for: items)
        let waiter = Task { await fixture.service.exportPlan(from: preparation) }
        await recorder.waitForCalls(1)

        waiter.cancel()

        #expect(await waiter.value == nil)
        #expect(fixture.service.exportPlanPreparation == nil)
    }

    @Test func retryAfterCancellingWaitsForTheAbandonedResolutions() async throws {
        let limit = LibraryService.exportPlanConcurrency
        let recorder = BookmarkResolutionRecorder { $0 <= limit }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        defer { recorder.release() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        var first: [MediaItem] = []
        for _ in 0..<limit { first.append(try fixture.insertItem(copying: source)) }
        let retried = [try fixture.insertItem(copying: source)]
        let old = fixture.service.beginExportPlanPreparation(for: first)
        await recorder.waitForCalls(limit)
        fixture.service.cancelExportPlanPreparation()
        #expect(await fixture.service.exportPlan(from: old) == nil)

        let retry = fixture.service.beginExportPlanPreparation(for: retried)
        // The abandoned resolutions still hold every slot, so the retry does not start another one.
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.workerCount == limit)
        #expect(retry.completedCount == 0)

        recorder.release(call: 1)
        let plan = try #require(await fixture.service.exportPlan(from: retry))
        #expect(plan.files.map(\.id) == retried.map(\.id))
        #expect(recorder.workerCount == limit + 1)
    }

    @Test func limiterHandsFreedSlotsToWaitersAndDropsCancelledOnes() async throws {
        let limiter = FileSystemWorkLimiter(limit: 1)
        try await limiter.acquire()
        let cancelled = Task { try await limiter.acquire() }
        let waiting = Task { try await limiter.acquire() }
        try await Task.sleep(for: .milliseconds(100))

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        limiter.release()

        try await waiting.value
        limiter.release()
        try await limiter.acquire()
    }

    /// Progress arrives through main-actor tasks sent by the workers, so the test yields until they run.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while condition() == false {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}

import Foundation
import Testing
@testable import SimpleMediaPlayer

/// Cancelling an import stops its whole-file reads, and cancel-and-retry cycles on a stalled file provider
/// cannot pile up blocked workers.
@MainActor
struct MediaImportStallTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringTheFingerprintStopsTheReadAndTheNextRequestStartsAtOnce() async throws {
        let probe = ChunkedFingerprintProbe(heldFileName: "large.wav")
        let fixture = try InspectionFixture(recorder: ImportOperationRecorder(), readFingerprint: probe.read)
        defer { fixture.remove() }
        let large = try fixture.makeAudio(named: "large.wav", amplitude: 0.1)
        let next = try fixture.makeAudio(named: "next.wav", amplitude: 0.2)
        let service = fixture.service
        let context = fixture.context

        let first = Task { @MainActor in
            defer { probe.taskEnded() }
            return await service.importFiles(from: [large], into: context, existingItems: [])
        }
        try #require(await probe.waitUntilPaused(), "the import ended before reading the fingerprint")
        first.cancel()
        let cancelledAt = ContinuousClock.now
        let second = await service.importFiles(from: [next], into: context, existingItems: [])
        let secondDuration = ContinuousClock.now - cancelledAt
        let firstSummary = await first.value

        #expect(probe.heldReadState == .stopped)
        #expect(probe.chunksRead < probe.chunkCount)
        // The second request read its file only after the first had stopped, not after it reached the end.
        #expect(probe.heldStatesWhenOtherReadsStarted == [.stopped])
        // The paused read waits up to 10 seconds for a cancellation that does not reach it.
        #expect(secondDuration < .seconds(5))
        #expect(firstSummary.createdCount == 0)
        #expect(firstSummary.errors.isEmpty)
        #expect(second.createdCount == 1)
        #expect(try fixture.items().map(\.title) == ["next"])
        #expect(try fixture.managedFiles().count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelAndRetryOnAStalledInspectionKeepsBlockedWorkersWithinTheLimit() async throws {
        let probe = StalledFileOperationProbe()
        defer { probe.release() }
        let fixture = try InspectionFixture(
            recorder: ImportOperationRecorder(), beforeIsVideoFile: { _ in probe.stall() }
        )
        defer { fixture.remove() }
        let service = fixture.service
        let context = fixture.context
        let limit = 2
        let attempts = limit + 3

        for attempt in 1...attempts {
            let source = try fixture.makeAudio(named: "song-\(attempt).wav", amplitude: Float(attempt) / 10)
            let caller = Task { @MainActor in
                await service.importFiles(from: [source], into: context, existingItems: [])
            }
            if attempt <= limit {
                try #require(await probe.waitForEntries(attempt, timeout: 10), "attempt \(attempt) did not stall")
            } else {
                // Within the limit this attempt waits for a slot instead, so the wait runs out.
                _ = await probe.waitForEntries(attempt, timeout: 0.5)
            }
            caller.cancel()
            let summary = await caller.value
            #expect(summary.createdCount == 0)
            #expect(summary.errors.isEmpty)
        }

        #expect(probe.maximumActive <= limit)
        #expect(probe.entries == limit)
        #expect(probe.active == limit)

        probe.release()
        #expect(probe.active == 0)
        let retry = try fixture.makeAudio(named: "retry.wav", amplitude: 0.9)
        let summary = await service.importFiles(from: [retry], into: context, existingItems: [])
        #expect(summary.createdCount == 1)
        #expect(try fixture.items().map(\.title) == ["retry"])
        #expect(try fixture.managedFiles().count == 1)
        #expect(fixture.pendingRemovals().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledImportStalledInTheDuplicateCheckNeitherBlocksTheNextNorCountsADuplicate() async throws {
        let probe = StalledFileOperationProbe()
        defer { probe.release() }
        let fixture = try InspectionFixture(recorder: ImportOperationRecorder(), beforeResolve: { probe.stall() })
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", amplitude: 0.1)
        let existing = try fixture.insertManagedCopy(of: source)
        let unrelated = try fixture.makeAudio(named: "unrelated.wav", amplitude: 0.3)
        let service = fixture.service
        let context = fixture.context

        // The existing item has the source's fingerprint, so checking whether its file is available stalls.
        let first = Task { @MainActor in
            await service.importFiles(from: [source], into: context, existingItems: [existing])
        }
        try #require(await probe.waitForEntries(1, timeout: 10), "the duplicate check did not stall")
        first.cancel()
        let cancelledAt = ContinuousClock.now
        let next = await service.importFiles(from: [unrelated], into: context, existingItems: [existing])
        let nextDuration = ContinuousClock.now - cancelledAt
        let firstSummary = await first.value

        // The next import finished while the cancelled check was still stalled; it stalls for up to 10 seconds.
        #expect(probe.active == 1)
        #expect(nextDuration < .seconds(5))
        #expect(next.createdCount == 1)
        #expect(firstSummary.duplicateCount == 0)
        #expect(firstSummary.createdCount == 0)
        #expect(firstSummary.errors.isEmpty)
        probe.release()
        #expect(try fixture.items().count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringTheCopyStopsItRemovesThePartialFileAndTheNextRequestProceeds() async throws {
        let probe = ChunkedCopyProbe(heldFileName: "large.wav")
        let fixture = try InspectionFixture(recorder: ImportOperationRecorder(), copyFile: probe.copy)
        defer { fixture.remove() }
        let large = try fixture.makeAudio(named: "large.wav", amplitude: 0.1)
        let next = try fixture.makeAudio(named: "next.wav", amplitude: 0.2)
        let service = fixture.service
        let context = fixture.context

        let first = Task { @MainActor in
            defer { probe.taskEnded() }
            return await service.importFiles(from: [large], into: context, existingItems: [])
        }
        try #require(await probe.waitUntilPaused(), "the import ended before copying the file")
        #expect(try fixture.managedFiles().count == 1)
        first.cancel()
        let cancelledAt = ContinuousClock.now
        let second = await service.importFiles(from: [next], into: context, existingItems: [])
        let secondDuration = ContinuousClock.now - cancelledAt
        let firstSummary = await first.value

        #expect(probe.heldCopyState == .stopped)
        #expect(probe.chunksWritten < probe.chunkCount)
        // The paused copy waits up to 10 seconds for a stop that does not reach it.
        #expect(secondDuration < .seconds(5))
        #expect(firstSummary.createdCount == 0)
        #expect(firstSummary.errors.isEmpty)
        #expect(second.createdCount == 1)
        let item = try #require(fixture.items().first)
        #expect(item.title == "next")
        #expect(try fixture.managedFiles().map(\.lastPathComponent) == [item.fileName])
        #expect(fixture.pendingRemovals().isEmpty)
    }
}

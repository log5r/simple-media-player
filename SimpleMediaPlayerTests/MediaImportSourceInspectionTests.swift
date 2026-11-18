import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

/// The import inspects files and creates bookmarks on `FileSystemWorkQueue`, and removes the managed copy
/// there when a later step fails or the caller cancels the import.
@MainActor
struct MediaImportSourceInspectionTests {
    @Test func inspectionAndBookmarkRunOffTheMainThreadAndUnreadableAudioIsRejected() async throws {
        let recorder = ImportOperationRecorder()
        let fixture = try InspectionFixture(recorder: recorder)
        defer { fixture.remove() }
        let valid = try fixture.makeAudio(named: "valid.wav")
        let broken = fixture.directory.appendingPathComponent("broken.wav")
        try Data(repeating: 0x5A, count: 4_096).write(to: broken)

        let summary = await fixture.service.importFiles(
            from: [valid, broken], into: fixture.context, existingItems: []
        )

        for operation in ImportOperationRecorder.Operation.allCases {
            let calls = recorder.calls(operation)
            #expect(calls.isEmpty == false, "\(operation) was not called")
            #expect(calls.allSatisfy { $0 == false }, "\(operation) ran on the main thread")
        }
        #expect(summary.createdCount == 1)
        let item = try #require(fixture.items().first)
        #expect(try fixture.items().count == 1)
        #expect(item.title == "valid")
        #expect(item.isVideo == false)
        #expect(item.duration > 0)
        #expect(try fixture.managedFiles().map(\.lastPathComponent) == [item.fileName])
        // The successful import neither journals nor removes its copy.
        #expect(fixture.pendingRemovals().isEmpty)
        #expect(recorder.removals().isEmpty)
        // `resolvedURL(for:)` falls back to the file name, so the bookmark is resolved on its own here.
        var isStale = false
        let bookmarked = try URL(
            resolvingBookmarkData: item.bookmarkData, options: bookmarkResolutionOptions, relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #expect(bookmarked.lastPathComponent == item.fileName)
        #expect(fixture.service.lastImportErrors.count == 1)
        #expect(fixture.service.lastImportErrors.first?.hasPrefix("broken.wav:") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerWhileTheBookmarkIsHeldRegistersNothing() async throws {
        let recorder = ImportOperationRecorder()
        let hold = ImportWorkerHold()
        defer { hold.release() }
        let fixture = try InspectionFixture(recorder: recorder, beforeBookmark: { _ in hold.hold() })
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        let service = fixture.service
        let context = fixture.context

        let caller = Task { @MainActor in
            defer { hold.taskEnded() }
            return await service.importFiles(from: [source], into: context, existingItems: [])
        }
        try #require(await hold.waitUntilHeld(), "the import ended before creating the bookmark")

        // The main actor keeps running while the worker is held.
        await Task { @MainActor in }.value
        let heldAt = try #require(hold.heldAt)
        #expect(ContinuousClock.now - heldAt < .seconds(5))
        #expect(try fixture.managedFiles().count == 1)

        caller.cancel()
        hold.release()
        let summary = await caller.value

        #expect(summary.createdCount == 0)
        #expect(summary.errors.isEmpty)
        #expect(try fixture.savedItemCount() == 0)
        #expect(try fixture.items().isEmpty)
        #expect(try fixture.managedFiles().isEmpty)
        #expect(fixture.pendingRemovals().isEmpty)
        let removals = recorder.removals()
        #expect(removals.count == 1)
        #expect(removals.allSatisfy { $0.isMainThread == false })
        // The removal was journaled under the media directory before it ran, and resolved from the path.
        #expect(removals.allSatisfy { $0.wasJournaled && $0.bookmarkWasEmpty })
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringTheSecondFileKeepsTheFirstAndReportsNoError() async throws {
        let hold = ImportWorkerHold(holdingCall: 2)
        defer { hold.release() }
        let fixture = try InspectionFixture(recorder: ImportOperationRecorder(), beforeBookmark: { _ in hold.hold() })
        defer { fixture.remove() }
        let first = try fixture.makeAudio(named: "first.wav", amplitude: 0.1)
        let second = try fixture.makeAudio(named: "second.wav", amplitude: 0.2)
        let service = fixture.service
        let context = fixture.context

        let caller = Task { @MainActor in
            defer { hold.taskEnded() }
            return await service.importFiles(from: [first, second], into: context, existingItems: [])
        }
        try #require(await hold.waitUntilHeld(), "the import ended before the second bookmark")
        caller.cancel()
        hold.release()
        let summary = await caller.value

        #expect(summary.createdCount == 1)
        #expect(summary.errors.isEmpty)
        #expect(fixture.service.lastImportErrors.isEmpty)
        #expect(try fixture.savedItemCount() == 1)
        let item = try #require(fixture.items().first)
        #expect(item.title == "first")
        #expect(try fixture.managedFiles().map(\.lastPathComponent) == [item.fileName])
        #expect(fixture.pendingRemovals().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingJustBeforeRegistrationDiscardsTheCopy() async throws {
        let recorder = ImportOperationRecorder()
        let registration = ImportRegistrationHold()
        defer { registration.release() }
        let fixture = try InspectionFixture(recorder: recorder, beforeImportRegistration: registration.hold)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        let service = fixture.service
        let context = fixture.context

        let caller = Task { @MainActor in
            defer { registration.taskEnded() }
            return await service.importFiles(from: [source], into: context, existingItems: [])
        }
        try #require(await registration.waitUntilHeld(), "the import ended before registering its item")
        #expect(try fixture.managedFiles().count == 1)
        caller.cancel()
        registration.release()
        let summary = await caller.value

        #expect(summary.createdCount == 0)
        #expect(summary.errors.isEmpty)
        #expect(try fixture.savedItemCount() == 0)
        #expect(try fixture.items().isEmpty)
        #expect(try fixture.managedFiles().isEmpty)
        #expect(fixture.pendingRemovals().isEmpty)
        #expect(recorder.removals().map(\.isMainThread) == [false])
    }
}

#if os(macOS)
private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
#endif

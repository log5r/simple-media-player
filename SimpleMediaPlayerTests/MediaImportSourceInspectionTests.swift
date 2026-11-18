import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

/// The import inspects files and creates bookmarks on `FileSystemWorkQueue`, and removes the managed copy
/// there when a later step fails or is cancelled.
@MainActor
struct MediaImportSourceInspectionTests {
    @Test func inspectionAndBookmarkRunOffTheMainThreadAndUnreadableAudioIsRejected() async throws {
        let recorder = ThreadRecorder()
        let fixture = try InspectionFixture(recorder: recorder)
        defer { fixture.remove() }
        let valid = try fixture.makeAudio(named: "valid.wav")
        let broken = fixture.directory.appendingPathComponent("broken.wav")
        try Data(repeating: 0x5A, count: 4_096).write(to: broken)

        let summary = await fixture.service.importFiles(
            from: [valid, broken], into: fixture.context, existingItems: []
        )

        for operation in ThreadRecorder.Operation.allCases {
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
        #expect(fixture.journal.entries(in: fixture.mediaDirectory).isEmpty)
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
    func cancellingWhileTheBookmarkIsHeldRemovesTheCopyOffTheMainThread() async throws {
        let recorder = ThreadRecorder()
        let hold = WorkerHold()
        defer { hold.release() }
        let fixture = try InspectionFixture(recorder: recorder, beforeBookmark: hold.hold)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        let service = fixture.service
        let session = MusicLibraryMetadataProvider().makeSession()
        let fingerprint = try MediaImportFingerprint.read(from: source)

        let task = Task { @MainActor in
            defer { hold.taskEnded() }
            _ = try await service.makeMediaItem(from: source, importFingerprint: fingerprint, musicSession: session)
        }
        try #require(await hold.waitUntilHeld(), "makeMediaItem ended before creating the bookmark")

        // The main actor keeps running while the worker is held.
        await Task { @MainActor in }.value
        let heldAt = try #require(hold.heldAt)
        #expect(ContinuousClock.now - heldAt < .seconds(5))
        #expect(try fixture.managedFiles().count == 1)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(try fixture.managedFiles().isEmpty)
        #expect(fixture.journal.entries(in: fixture.mediaDirectory).isEmpty)
        let removals = recorder.removals()
        #expect(removals.count == 1)
        #expect(removals.allSatisfy { $0.isMainThread == false })
        // The removal was journaled under the media directory before it ran, and resolved from the path.
        #expect(removals.allSatisfy { $0.wasJournaled && $0.bookmarkWasEmpty })
        #expect(try fixture.items().isEmpty)
        hold.release()
    }
}

#if os(macOS)
private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
#endif

@MainActor
private struct InspectionFixture {
    let directory: URL
    let mediaDirectory: URL
    let container: ModelContainer
    let service: LibraryService
    let journal: PendingFileRemovalJournal
    private let journalSuiteName = "MediaImportSourceInspectionTests-\(UUID().uuidString)"
    var context: ModelContext { container.mainContext }

    init(recorder: ThreadRecorder, beforeBookmark: @escaping @Sendable () -> Void = {}) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mediaDirectory = directory.appendingPathComponent("Media")
        self.mediaDirectory = mediaDirectory
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        let journal = PendingFileRemovalJournal(defaults: try #require(UserDefaults(suiteName: journalSuiteName)))
        self.journal = journal
        let defaults = ImportFileOperations()
        let operations = ImportFileOperations(
            isVideoFile: { url in
                recorder.record(.isVideoFile)
                return defaults.isVideoFile(url)
            },
            openAudioFile: { url in
                recorder.record(.openAudioFile)
                try defaults.openAudioFile(url)
            },
            makeBookmark: { url in
                recorder.record(.makeBookmark)
                beforeBookmark()
                return try defaults.makeBookmark(url)
            }
        )
        // The import resolves bookmarks only to remove a discarded copy.
        let resolveBookmark: @Sendable (Data, URL) -> URL = { bookmarkData, fallbackURL in
            let journaledIDs = journal.entries(in: mediaDirectory).map(\.id.uuidString)
            recorder.recordRemoval(.init(
                isMainThread: Thread.isMainThread,
                wasJournaled: journaledIDs.contains(fallbackURL.deletingPathExtension().lastPathComponent),
                bookmarkWasEmpty: bookmarkData.isEmpty
            ))
            return EmbeddedMetadataEditabilityChecker.resolve(bookmarkData, fallbackURL)
        }
        service = LibraryService(
            mediaDirectoryURL: mediaDirectory, resolveBookmark: resolveBookmark, removalJournal: journal,
            importFileOperations: operations
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: journalSuiteName)?.removePersistentDomain(forName: journalSuiteName)
    }

    func makeAudio(named name: String, frameCount: AVAudioFrameCount = 4_410) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try #require(buffer.floatChannelData?[0]).update(repeating: 0.1, count: Int(frameCount))
        try file.write(from: buffer)
        return url
    }

    func items() throws -> [MediaItem] { try context.fetch(FetchDescriptor<MediaItem>()) }

    func managedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
    }
}

/// Records whether each replaced file operation ran on the main thread.
nonisolated private final class ThreadRecorder: @unchecked Sendable {
    enum Operation: CaseIterable { case isVideoFile, openAudioFile, makeBookmark }

    struct Removal {
        let isMainThread: Bool
        let wasJournaled: Bool
        let bookmarkWasEmpty: Bool
    }

    private let lock = NSLock()
    private var operationCalls: [Operation: [Bool]] = [:]
    private var removalCalls: [Removal] = []

    func record(_ operation: Operation) {
        let isMainThread = Thread.isMainThread
        lock.withLock { operationCalls[operation, default: []].append(isMainThread) }
    }

    func recordRemoval(_ removal: Removal) {
        lock.withLock { removalCalls.append(removal) }
    }

    /// Whether each call ran on the main thread.
    func calls(_ operation: Operation) -> [Bool] {
        lock.withLock { operationCalls[operation] ?? [] }
    }

    func removals() -> [Removal] {
        lock.withLock { removalCalls }
    }
}

/// Holds a `FileSystemWorkQueue` worker, which is not a cooperative thread, until the test releases it.
nonisolated private final class WorkerHold: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var isReleased = false
    private var heldTime: ContinuousClock.Instant?

    var heldAt: ContinuousClock.Instant? { lock.withLock { heldTime } }

    func hold() {
        lock.withLock { heldTime = .now }
        finishWaiting(held: true)
        _ = semaphore.wait(timeout: .now() + 10)
    }

    /// Lets a test that waits for the hold stop when the work ends without reaching it.
    func taskEnded() { finishWaiting(held: false) }

    /// Returns true once the worker is held, or false when the task ended first.
    func waitUntilHeld() async -> Bool {
        await withCheckedContinuation { continuation in
            let outcome: Bool? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let outcome { continuation.resume(returning: outcome) }
        }
    }

    func release() {
        let shouldSignal = lock.withLock {
            defer { isReleased = true }
            return isReleased == false
        }
        if shouldSignal { semaphore.signal() }
    }

    private func finishWaiting(held: Bool) {
        let waiter: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = held
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: held)
    }
}

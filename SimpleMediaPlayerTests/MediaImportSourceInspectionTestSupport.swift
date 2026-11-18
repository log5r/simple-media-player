import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

/// A library whose import file operations and bookmark resolution record where they run.
@MainActor
struct InspectionFixture {
    let directory: URL
    let mediaDirectory: URL
    let container: ModelContainer
    let service: LibraryService
    let journal: PendingFileRemovalJournal
    private let journalSuiteName = "MediaImportSourceInspectionTests-\(UUID().uuidString)"
    var context: ModelContext { container.mainContext }

    init(
        recorder: ImportOperationRecorder,
        beforeBookmark: @escaping @Sendable (URL) throws -> Void = { _ in },
        beforeImportRegistration: @escaping @MainActor (URL) async -> Void = { _ in }
    ) throws {
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
                try beforeBookmark(url)
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
            importFileOperations: operations, beforeImportRegistration: beforeImportRegistration
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: journalSuiteName)?.removePersistentDomain(forName: journalSuiteName)
    }

    func makeAudio(named name: String, amplitude: Float = 0.1, frameCount: AVAudioFrameCount = 4_410) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try #require(buffer.floatChannelData?[0]).update(repeating: amplitude, count: Int(frameCount))
        try file.write(from: buffer)
        return url
    }

    func items() throws -> [MediaItem] { try context.fetch(FetchDescriptor<MediaItem>()) }

    /// Items in the store, read through a separate context so unsaved insertions are not counted.
    func savedItemCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<MediaItem>())
    }

    func managedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
    }
}

/// Records whether each replaced file operation, and each removal of a discarded copy, ran on the main thread.
nonisolated final class ImportOperationRecorder: @unchecked Sendable {
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

/// Holds a `FileSystemWorkQueue` worker, which is not a cooperative thread, on the given call until the test
/// releases it. Earlier calls pass through.
nonisolated final class ImportWorkerHold: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let heldCall: Int
    private var callCount = 0
    private var outcome: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var isReleased = false
    private var heldTime: ContinuousClock.Instant?

    init(holdingCall heldCall: Int = 1) {
        self.heldCall = heldCall
    }

    var heldAt: ContinuousClock.Instant? { lock.withLock { heldTime } }

    func hold() {
        let isHeldCall = lock.withLock {
            callCount += 1
            guard callCount == heldCall else { return false }
            heldTime = .now
            return true
        }
        guard isHeldCall else { return }
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

/// Holds an import just before it registers its item, without polling for the arrival.
@MainActor
final class ImportRegistrationHold {
    private var outcome: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var held: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func hold(_ url: URL) async {
        guard isReleased == false else { return }
        finishWaiting(held: true)
        await withCheckedContinuation { held = $0 }
    }

    func taskEnded() { finishWaiting(held: false) }

    /// Returns true once the import is held, or false when the task ended first.
    func waitUntilHeld() async -> Bool {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        isReleased = true
        held?.resume()
        held = nil
    }

    private func finishWaiting(held: Bool) {
        guard outcome == nil else { return }
        outcome = held
        waiter?.resume(returning: held)
        waiter = nil
    }
}

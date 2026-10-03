import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct EmbeddedMetadataEditabilityTests {
    @Test(arguments: EditabilityOperation.blockingOperations)
    private func blockedSynchronousCheckKeepsMainActorResponsive(operation: EditabilityOperation) async throws {
        let directory = try editabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = EditabilityProbe(blocking: operation)
        let service = LibraryService(mediaDirectoryURL: directory, editabilityChecker: probe.checker)
        let items = [editabilityItem("first.wav"), editabilityItem("second.flac")]
        let task = Task { @MainActor in try await service.editableMetadataItemIDs(for: items) }
        defer { task.cancel(); probe.release() }

        try await probe.waitUntilBlocked()
        let start = ContinuousClock.now
        let heartbeat = Task { @MainActor in Thread.isMainThread }
        #expect(await heartbeat.value)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(probe.isBlocked)
        #expect(probe.mainThreadCalls == 0)

        probe.release()
        #expect(try await task.value == Set(items.map(\.id)))
        #expect(probe.resolutions == items.count)
        #expect(probe.writeProbes == items.count)
        #expect(probe.mainThreadCalls == 0)
        #expect(probe.timedOut == false)
    }

    @Test func alreadyCancelledRequestPerformsNoSynchronousWork() async throws {
        let directory = try editabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = EditabilityProbe()
        let checker = probe.checker
        let inputs = [editabilityInput("first.wav"), editabilityInput("second.flac")]
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await checker.editableIDs(for: inputs, fallbackDirectory: { probe.fallback(directory) })
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.fallbacks == 0)
        #expect(probe.resolutions == 0)
        #expect(probe.writeProbes == 0)
    }

    @Test(arguments: EditabilityOperation.allOperations)
    private func cancellationRejectsLateResultsAndStopsFollowingInputs(operation: EditabilityOperation) async throws {
        let directory = try editabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = EditabilityProbe(blocking: operation)
        let checker = probe.checker
        let inputs = ["first.wav", "second.flac", "third.opus"].map(editabilityInput)
        let task = Task { @MainActor in
            try await checker.editableIDs(for: inputs, fallbackDirectory: { probe.fallback(directory) })
        }
        defer { task.cancel(); probe.release() }
        try await probe.waitUntilBlocked()

        task.cancel()
        probe.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.fallbacks == 1)
        #expect(probe.resolutions == (operation == .fallback ? 0 : 1))
        #expect(probe.writeProbes == (operation == .writeProbe ? 1 : 0))
        #expect(probe.mainThreadCalls == 0)
        #expect(probe.timedOut == false)
    }

    @Test(arguments: EditabilityWrite.allCases, EditabilityInvalidation.allCases)
    private func invalidatedPrewriteCheckCannotChangeFilesOrModel(
        operation: EditabilityWrite,
        invalidation: EditabilityInvalidation
    ) async throws {
        let probe = EditabilityProbe(blocking: .writeProbe)
        let fixture = try EditabilityWriteFixture(checker: probe.checker)
        defer { fixture.remove() }
        var draft = MediaMetadataEditDraft(item: fixture.item)
        draft.title = "Edited title"
        draft.lyrics = "Edited lyrics"
        let editDraft = draft
        let task = Task { @MainActor in
            switch operation {
            case .lyrics:
                try await fixture.service.saveLyrics(
                    "Edited lyrics", for: fixture.item, embedInFile: true, in: fixture.context
                )
            case .metadata:
                try await fixture.service.updateEmbeddedMetadata(
                    for: fixture.item, draft: editDraft, in: fixture.context
                )
            }
        }
        defer { task.cancel(); probe.release() }
        try await probe.waitUntilBlocked()

        switch invalidation {
        case .deletion:
            fixture.context.delete(fixture.item)
        case .fileChange:
            fixture.item.fileName = fixture.replacementURL.lastPathComponent
        }
        try fixture.context.save()
        probe.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: fixture.sourceURL) == fixture.sourceBytes)
        #expect(try Data(contentsOf: fixture.replacementURL) == fixture.replacementBytes)
        let persisted = try ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>())
        #expect(persisted.count == (invalidation == .deletion ? 0 : 1))
        #expect(persisted.first?.title != "Edited title")
        #expect(persisted.first?.lyricsRaw != "Edited lyrics")
        #expect(probe.writeProbes == 1)
        #expect(probe.mainThreadCalls == 0)
        #expect(probe.timedOut == false)
    }

    @Test func bookmarkResolutionWinsAndMalformedBookmarkUsesManagedFallback() async throws {
        let directory = try editabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let managed = directory.appendingPathComponent("Managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("bookmarked.wav")
        try FileManager.default.copyItem(at: editabilityAudioFixture("wav"), to: source)
        let fallback = managed.appendingPathComponent("fallback.flac")
        try FileManager.default.copyItem(at: editabilityAudioFixture("flac"), to: fallback)
        let unsupported = directory.appendingPathComponent("bookmarked.txt")
        try Data("unsupported".utf8).write(to: unsupported)
        #if os(macOS)
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = try source.bookmarkData(
            options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let unsupportedBookmark = try unsupported.bookmarkData(
            options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let bookmarked = editabilityItem("missing.wav", bookmark: bookmark)
        let malformed = editabilityItem(fallback.lastPathComponent)
        let unsupportedItem = editabilityItem(fallback.lastPathComponent, bookmark: unsupportedBookmark)
        let service = LibraryService(mediaDirectoryURL: managed)

        let ids = try await service.editableMetadataItemIDs(for: [bookmarked, malformed, unsupportedItem])

        #expect(ids == [bookmarked.id, malformed.id])
        #expect(try await service.canEditEmbeddedMetadata(for: bookmarked))
        #expect(try await service.canEditEmbeddedMetadata(for: unsupportedItem) == false)
    }

    @Test(arguments: ["wav", "flac", "ogg", "oga", "opus"])
    func validAdditionalAudioIsEditableWhileInvalidAndMissingFilesAreRejected(fileExtension: String) async throws {
        let directory = try editabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let validURL = directory.appendingPathComponent("valid.\(fileExtension)")
        try FileManager.default.copyItem(at: editabilityAudioFixture(fileExtension), to: validURL)
        let invalidURL = directory.appendingPathComponent("invalid.\(fileExtension)")
        try Data("invalid audio".utf8).write(to: invalidURL)
        let valid = editabilityItem(validURL.lastPathComponent)
        let invalid = editabilityItem(invalidURL.lastPathComponent)
        let missing = editabilityItem("missing.\(fileExtension)")
        let unsupported = editabilityItem("unsupported.wma")
        let service = LibraryService(mediaDirectoryURL: directory)

        #expect(try await service.editableMetadataItemIDs(for: [valid, invalid, missing, unsupported]) == [valid.id])
        #expect(try await service.canEditEmbeddedMetadata(for: valid))
        #expect(try await service.canEditEmbeddedMetadata(for: invalid) == false)
        #expect(try await service.canEditEmbeddedMetadata(for: missing) == false)
        #expect(try await service.canEditEmbeddedMetadata(for: unsupported) == false)
    }

    @Test(arguments: ["mp3", "m4a", "m4v", "mp4", "mov", "aif", "aiff", "aifc"])
    func existingExtensionBasedEligibilityIsPreservedForMissingFiles(fileExtension: String) async throws {
        let directory = try editabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = editabilityItem("missing.\(fileExtension)")
        let service = LibraryService(mediaDirectoryURL: directory)

        #expect(try await service.canEditEmbeddedMetadata(for: item))
        #expect(try await service.editableMetadataItemIDs(for: [item]) == [item.id])
    }

    @Test func threeThousandMixedSnapshotsResolveAndProbeOffMainThread() async throws {
        let directory = try editabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioNames = ["valid.wav", "valid.flac", "valid.ogg", "valid.opus"]
        for name in audioNames {
            let fileExtension = URL(fileURLWithPath: name).pathExtension
            try FileManager.default.copyItem(
                at: editabilityAudioFixture(fileExtension), to: directory.appendingPathComponent(name)
            )
        }
        try Data("invalid audio".utf8).write(to: directory.appendingPathComponent("invalid.flac"))
        try Data("unsupported".utf8).write(to: directory.appendingPathComponent("unsupported.wma"))
        let names = audioNames + ["invalid.flac", "unsupported.wma", "missing.opus", "missing.mp3"]
        // Distinct selectable IDs exercise a large selection without duplicating the same audio bytes 3,000 times.
        let inputs = (0..<3_000).map { editabilityInput(names[$0 % names.count]) }
        let expected = Set(inputs.filter { audioNames.contains($0.fileName) || $0.fileName == "missing.mp3" }.map(\.id))
        let probe = EditabilityProbe(useRealOperations: true)
        let checker = probe.checker
        let start = ContinuousClock.now

        let ids = try await checker.editableIDs(for: inputs, fallbackDirectory: { probe.fallback(directory) })
        let elapsed = ContinuousClock.now - start

        #expect(ids == expected)
        #expect(probe.fallbacks == 1)
        #expect(probe.resolutions == 3_000)
        #expect(probe.writeProbes == 3_000)
        #expect(probe.mainThreadCalls == 0)
        #expect(elapsed < .seconds(30), "The 3,000-item mixed scan took \(elapsed)")
    }
}

nonisolated private enum EditabilityOperation: Hashable, Sendable {
    case fallback
    case resolve
    case writeProbe

    static let blockingOperations: [Self] = [.resolve, .writeProbe]
    static let allOperations: [Self] = [.fallback, .resolve, .writeProbe]
}

nonisolated private enum EditabilityWrite: CaseIterable {
    case lyrics
    case metadata
}

nonisolated private enum EditabilityInvalidation: CaseIterable {
    case deletion
    case fileChange
}

@MainActor
private struct EditabilityWriteFixture {
    let directory: URL
    let sourceURL: URL
    let replacementURL: URL
    let sourceBytes: Data
    let replacementBytes: Data
    let container: ModelContainer
    let item: MediaItem
    let service: LibraryService
    var context: ModelContext { container.mainContext }

    init(checker: EmbeddedMetadataEditabilityChecker) throws {
        directory = try editabilityDirectory()
        sourceURL = directory.appendingPathComponent("source.mp3")
        replacementURL = directory.appendingPathComponent("replacement.mp3")
        let audioPayload = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        try audioPayload.write(to: sourceURL)
        try ID3TagWriter.write(
            MediaMetadataEditDraft(title: "Original title", artist: "", album: "", genre: "",
                                   lyrics: "Original lyrics", editsLyrics: true),
            to: sourceURL
        )
        sourceBytes = try Data(contentsOf: sourceURL)
        replacementBytes = audioPayload
        try replacementBytes.write(to: replacementURL)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        item = MediaItem(
            title: "Original title", duration: 1, isVideo: false, lyricsRaw: "Original lyrics",
            bookmarkData: Data([0xFF]), fileName: sourceURL.lastPathComponent
        )
        container.mainContext.insert(item)
        try container.mainContext.save()
        service = LibraryService(mediaDirectoryURL: directory, editabilityChecker: checker)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

nonisolated private final class EditabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blocking: EditabilityOperation?
    private let useRealOperations: Bool
    private var counts: [EditabilityOperation: Int] = [:]
    private var mainCalls = 0
    private var blocked = false
    private var didTimeOut = false

    init(blocking: EditabilityOperation? = nil, useRealOperations: Bool = false) {
        self.blocking = blocking
        self.useRealOperations = useRealOperations
    }

    var checker: EmbeddedMetadataEditabilityChecker {
        EmbeddedMetadataEditabilityChecker(resolve: resolve, canWrite: canWrite)
    }

    var fallbacks: Int { lock.withLock { counts[.fallback, default: 0] } }
    var resolutions: Int { lock.withLock { counts[.resolve, default: 0] } }
    var writeProbes: Int { lock.withLock { counts[.writeProbe, default: 0] } }
    var mainThreadCalls: Int { lock.withLock { mainCalls } }
    var isBlocked: Bool { lock.withLock { blocked } }
    var timedOut: Bool { lock.withLock { didTimeOut } }

    func fallback(_ directory: URL) -> URL {
        record(.fallback)
        return directory
    }

    func resolve(_ bookmark: Data, _ fallback: URL) -> URL {
        record(.resolve)
        return useRealOperations ? EmbeddedMetadataEditabilityChecker.resolve(bookmark, fallback) : fallback
    }

    func canWrite(_ url: URL) -> Bool {
        record(.writeProbe)
        return useRealOperations ? EmbeddedMetadataEditabilityChecker.canWrite(url) : true
    }

    func release() { gate.signal() }

    func waitUntilBlocked() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while isBlocked == false, timedOut == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(isBlocked, "The synchronous editability operation did not block before the deadline")
        try #require(timedOut == false, "The worker blocked the MainActor until its gate timed out")
    }

    private func record(_ operation: EditabilityOperation) {
        let shouldBlock = lock.withLock {
            counts[operation, default: 0] += 1
            if Thread.isMainThread { mainCalls += 1 }
            let shouldBlock = operation == blocking && counts[operation] == 1
            if shouldBlock { blocked = true }
            return shouldBlock
        }
        guard shouldBlock else { return }
        let result = gate.wait(timeout: .now() + 2)
        lock.withLock {
            blocked = false
            if result == .timedOut { didTimeOut = true }
        }
    }
}

@MainActor
private func editabilityItem(_ fileName: String, bookmark: Data = Data([0xFF])) -> MediaItem {
    MediaItem(title: fileName, duration: 1, isVideo: false, bookmarkData: bookmark, fileName: fileName)
}

nonisolated private func editabilityInput(_ fileName: String) -> EmbeddedMetadataEditabilityChecker.Input {
    EmbeddedMetadataEditabilityChecker.Input(id: UUID(), bookmarkData: Data([0xFF]), fileName: fileName)
}

private func editabilityDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func editabilityAudioFixture(_ fileExtension: String) -> URL {
    let fixtureExtension = fileExtension == "oga" ? "ogg" : fileExtension
    if let bundled = Bundle.allBundles.compactMap({
        $0.url(forResource: "tag-test", withExtension: fixtureExtension)
    }).first {
        return bundled
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/tag-test.\(fixtureExtension)")
}

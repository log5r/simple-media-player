import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct BulkMetadataEditCancellationTests {
    /// The bulk path does not read artwork, so it is held at the editability check right before the write.
    /// Replacing the item's artwork is not covered here: a text-only bulk edit neither reads nor writes artwork.
    @Test(arguments: BulkWriteInvalidation.allCases)
    private func invalidationBeforeTheWriteKeepsABulkTitleEditOutOfTheFile(
        invalidation: BulkWriteInvalidation
    ) async throws {
        let probe = MetadataDraftReadProbe(blocks: false)
        let gate = EditabilityCheckGate()
        let fixture = try MetadataDraftFixture(probe: probe, canWrite: gate.canWrite)
        defer { fixture.remove() }
        let sourceBytes = try Data(contentsOf: fixture.sourceURL)
        var draft = MediaMetadataEditDraft(item: fixture.item)
        draft.title = "Bulk replacement title"
        let patch = MediaMetadataEditPatch(fields: [.title], draft: draft)
        let task = Task { @MainActor in
            let result = await fixture.service.updateEmbeddedMetadata(
                for: [fixture.item], patch: patch, in: fixture.context
            )
            gate.endWait()
            return result
        }
        defer { task.cancel(); gate.release() }
        try await gate.waitUntilChecking()

        switch invalidation {
        case .cancellation:
            task.cancel()
        case .deletion:
            fixture.context.delete(fixture.item)
            try fixture.context.save()
        }
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        gate.release()
        let result = await task.value

        #expect(result.updatedCount == 0)
        if invalidation == .cancellation {
            // A stopped request leaves the item unprocessed instead of reporting it as a failure.
            #expect(result.failedCount == 0)
            #expect(result.unprocessedCount == 1)
        } else {
            #expect(result.failedCount == 1)
            #expect(result.unprocessedCount == 0)
            #expect(result.failures.first?.fileName == fixture.sourceURL.lastPathComponent)
        }
        #expect(try Data(contentsOf: fixture.sourceURL) == sourceBytes)
        let persisted = try ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>())
        if invalidation == .deletion {
            #expect(persisted.isEmpty)
        } else {
            #expect(fixture.item.title == "Model title")
            #expect(persisted.first?.title == "Model title")
        }
        #expect(probe.readCount == 0)
        #expect(probe.thumbnailCount == 0)
    }

    @Test func bulkEditReportsProgressForUpdatedAndFailedItems() async throws {
        let probe = MetadataDraftReadProbe(blocks: false)
        let fixture = try BulkEditFixture(fileCount: 2, probe: probe, missingFileIndex: 1)
        defer { fixture.remove() }
        let patch = fixture.titlePatch
        let task = Task { @MainActor in
            var reports: [BulkMetadataEditProgress] = []
            let result = await fixture.service.updateEmbeddedMetadata(
                for: fixture.items, patch: patch, in: fixture.context
            ) { reports.append($0) }
            return (result, reports)
        }
        let (result, reports) = await task.value

        #expect(result.updatedCount == 2)
        #expect(result.failedCount == 1)
        #expect(result.unprocessedCount == 0)
        #expect(reports == (1...3).map { BulkMetadataEditProgress(completedCount: $0, totalCount: 3) })
    }

    @Test func cancellingAfterTheFirstItemLeavesTheRemainingFilesUntouched() async throws {
        let probe = MetadataDraftReadProbe(blocks: false)
        let fixture = try BulkEditFixture(fileCount: 3, probe: probe)
        defer { fixture.remove() }
        let originals = try fixture.urls.map { try Data(contentsOf: $0) }
        let patch = fixture.titlePatch
        let task = Task { @MainActor in
            var reports: [BulkMetadataEditProgress] = []
            let result = await fixture.service.updateEmbeddedMetadata(
                for: fixture.items, patch: patch, in: fixture.context
            ) { progress in
                reports.append(progress)
                if progress.completedCount == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return (result, reports)
        }
        let (result, reports) = await task.value

        #expect(result.updatedCount == 1)
        #expect(result.failedCount == 0)
        #expect(result.unprocessedCount == 2)
        #expect(reports == [BulkMetadataEditProgress(completedCount: 1, totalCount: 3)])
        #expect(try Data(contentsOf: fixture.urls[0]) != originals[0])
        #expect(fixture.items[0].title == "Bulk title")
        for index in 1..<3 {
            #expect(try Data(contentsOf: fixture.urls[index]) == originals[index])
            #expect(fixture.items[index].title == "Model title")
        }
    }

    /// A stop that arrives while the first item's save is failing must not hide that failure.
    @Test func aFailureAfterCancellationIsReportedAndTheRemainingFilesStayUntouched() async throws {
        let probe = MetadataDraftReadProbe(blocks: false)
        let fixture = try BulkEditFixture(fileCount: 3, probe: probe) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw InjectedSaveFailure()
        }
        defer { fixture.remove() }
        let originals = try fixture.urls.map { try Data(contentsOf: $0) }
        let patch = fixture.titlePatch
        let task = Task { @MainActor in
            var reports: [BulkMetadataEditProgress] = []
            let result = await fixture.service.updateEmbeddedMetadata(
                for: fixture.items, patch: patch, in: fixture.context
            ) { reports.append($0) }
            return (result, reports)
        }
        let (result, reports) = await task.value

        #expect(result.updatedCount == 0)
        #expect(result.failedCount == 1)
        #expect(result.failures.first?.fileName == fixture.urls[0].lastPathComponent)
        #expect(result.unprocessedCount == 2)
        #expect(reports == [BulkMetadataEditProgress(completedCount: 1, totalCount: 3)])
        for index in 1..<3 {
            #expect(try Data(contentsOf: fixture.urls[index]) == originals[index])
            #expect(fixture.items[index].title == "Model title")
        }
    }

    @Test(arguments: [false, true])
    func bulkEditDoesNotLoadLibraryOrEmbeddedArtwork(patchesArtwork: Bool) async throws {
        let probe = MetadataDraftReadProbe(blocks: false)
        let fixture = try BulkEditFixture(fileCount: 2, probe: probe, useWAV: false)
        defer { fixture.remove() }
        var patch = fixture.titlePatch
        if patchesArtwork {
            patch.fields.insert(.artwork)
            patch.draft.artworkData = fixture.embeddedArtwork
        }

        let result = await fixture.service.updateEmbeddedMetadata(
            for: fixture.items, patch: patch, in: fixture.context
        )

        #expect(result.updatedCount == 2)
        #expect(probe.readCount == 0)
        #expect(probe.thumbnailCount == 0)
        for item in fixture.items {
            #expect(item.title == "Bulk title")
            #expect(item.artworkData == (patchesArtwork ? fixture.embeddedArtwork : Data([1, 2, 3])))
        }
    }
}

nonisolated private enum BulkWriteInvalidation: CaseIterable {
    case cancellation
    case deletion
}

nonisolated private struct InjectedSaveFailure: Error {}

@MainActor
private struct BulkEditFixture {
    let directory: URL
    let urls: [URL]
    let embeddedArtwork: Data
    let container: ModelContainer
    let service: LibraryService
    let items: [MediaItem]
    var context: ModelContext { container.mainContext }
    var titlePatch: MediaMetadataEditPatch {
        MediaMetadataEditPatch(
            fields: [.title], draft: MediaMetadataEditDraft(title: "Bulk title", artist: "", album: "", genre: "")
        )
    }

    /// `missingFileIndex` adds an item whose file does not exist, inserted at that position.
    init(
        fileCount: Int, probe: MetadataDraftReadProbe, useWAV: Bool = true, missingFileIndex: Int? = nil,
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        embeddedArtwork = try makeDraftArtwork()
        let fileExtension = useWAV ? "wav" : "mp4"
        var urls: [URL] = []
        for index in 0..<fileCount {
            let url = directory.appendingPathComponent("source-\(index).\(fileExtension)")
            try writeDraftAudio(to: url, useWAV: useWAV)
            let metadata = MediaMetadataEditDraft(
                title: "Embedded title \(index)", artist: "Embedded artist", album: "Embedded album", genre: "",
                artworkData: embeddedArtwork, editsArtwork: true
            )
            if useWAV {
                try WAVMetadataWriter.write(metadata, to: url)
            } else {
                try MP4MetadataWriter.write(metadata, to: url)
            }
            urls.append(url)
        }
        self.urls = urls
        var itemURLs = urls
        if let missingFileIndex {
            itemURLs.insert(directory.appendingPathComponent("missing.\(fileExtension)"), at: missingFileIndex)
        }
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        items = itemURLs.map { url in
            MediaItem(
                title: "Model title", artist: "Model artist", album: "Model album", duration: 0.1,
                isVideo: useWAV == false, bookmarkData: Data([0xFF]),
                artworkData: Data([1, 2, 3]), fileName: url.lastPathComponent
            )
        }
        for item in items { container.mainContext.insert(item) }
        try container.mainContext.save()
        service = LibraryService(
            mediaDirectoryURL: directory,
            artworkProcessor: ArtworkProcessor(downsample: probe.thumbnail),
            artworkLoader: LibraryArtworkLoader(read: probe.read),
            saveContext: saveContext
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Holds the bulk path at the editability check, the last step before the file write.
/// The test waits with a continuation, so no cooperative thread is needed to notice the check.
nonisolated private final class EditabilityCheckGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var checks = 0
    private var isWaitOver = false
    private var waiter: CheckedContinuation<Void, Never>?

    var checkCount: Int { lock.withLock { checks } }

    func canWrite(_ url: URL) -> Bool {
        lock.withLock { checks += 1 }
        endWait()
        _ = gate.wait(timeout: .now() + 10)
        return EmbeddedMetadataEditabilityChecker.canWrite(url)
    }

    func release() { gate.signal() }

    /// Called when the check starts and when the bulk edit returns, so a missed check cannot hang the test.
    func endWait() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isWaitOver = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }

    func waitUntilChecking() async throws {
        await withCheckedContinuation { continuation in
            let resumesNow = lock.withLock {
                if isWaitOver { return true }
                waiter = continuation
                return false
            }
            if resumesNow { continuation.resume() }
        }
        try #require(checkCount == 1, "The bulk edit returned without reaching the editability check")
    }
}

import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryBookmarkResolutionTests {
    @Test func importIntoLegacyLibraryResolvesBookmarksOutsideTheMainThread() async throws {
        let recorder = BookmarkResolutionRecorder()
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let other = try fixture.makeAudio(named: "other.wav", frameCount: 8_820)
        for _ in 0..<20 { _ = try fixture.insertItem(copying: other) }
        let legacy = try fixture.insertItem(copying: source)

        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])

        #expect(fixture.service.lastImportErrors.isEmpty)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 21)
        #expect(legacy.importFingerprint == (try MediaImportFingerprint.read(from: source)))
        #expect(recorder.mainThreadCount == 0)
        #expect(recorder.workerCount >= 21)
    }

    @Test func exportPlanKeepsSelectionOrderAndResolvesOutsideTheMainThread() async throws {
        let recorder = BookmarkResolutionRecorder()
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        var items: [MediaItem] = []
        for _ in 0..<(LibraryService.exportPlanConcurrency * 3 + 1) {
            items.append(try fixture.insertItem(copying: source))
        }

        let plan = try await fixture.service.makeExportPlan(for: items)

        #expect(plan.files.map(\.id) == items.map(\.id))
        #expect(plan.files.map(\.originalFileName) == items.map(\.fileName))
        #expect(plan.files.map(\.sourceURL) == items.map { fixture.mediaDirectory.appendingPathComponent($0.fileName) })
        #expect(plan.preparationErrors.isEmpty)
        #expect(recorder.mainThreadCount == 0)
        #expect(recorder.workerCount == items.count)
    }

    @Test func cancelledExportPlanStopsBeforeVisitingEveryItem() async throws {
        let recorder = BookmarkResolutionRecorder(blocksUntilReleased: true)
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        var items: [MediaItem] = []
        for _ in 0..<(LibraryService.exportPlanConcurrency * 5) {
            items.append(try fixture.insertItem(copying: source))
        }
        let task = Task { try await fixture.service.makeExportPlan(for: items) }
        defer { recorder.release() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while recorder.workerCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(recorder.workerCount > 0)
        task.cancel()
        recorder.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.workerCount <= LibraryService.exportPlanConcurrency * 2)
        #expect(recorder.mainThreadCount == 0)
    }

    @Test(arguments: ["wav", "mp4"])
    func exportMetadataRethrowsCancellationInsteadOfFallingBack(fileExtension: String) async throws {
        let fixture = try BookmarkFixture(recorder: BookmarkResolutionRecorder())
        defer { fixture.remove() }
        let wav = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let source = fixture.directory.appendingPathComponent("song").appendingPathExtension(fileExtension)
        if source != wav { try FileManager.default.copyItem(at: wav, to: source) }
        #expect(try await LibraryService.exportMetadata(for: source).title == nil)

        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LibraryService.exportMetadata(for: source)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func deleteRemovesTheItemImmediatelyAndTheFileInAWorker() async throws {
        let recorder = BookmarkResolutionRecorder()
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)

        let removal = fixture.service.delete(item, from: fixture.context)

        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
        await removal?.value
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(recorder.mainThreadCount == 0)
        #expect(recorder.workerCount == 1)
    }

    @Test func importAfterDeletionWaitsForTheFileRemovalBeforeCheckingDuplicates() async throws {
        let recorder = BookmarkResolutionRecorder(blocksUntilReleased: true, blockedCallCount: 1)
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        item.importFingerprint = try MediaImportFingerprint.read(from: source)
        try fixture.context.save()
        defer { recorder.release() }

        fixture.service.delete(item, from: fixture.context)
        // The caller's snapshot still lists the deleted item while its file removal is blocked.
        let importTask = Task {
            await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [item])
        }
        // Without waiting for the removal, the import finishes here and skips the file as a duplicate.
        try await Task.sleep(for: .milliseconds(200))
        recorder.release()
        await importTask.value

        let items = try fixture.context.fetch(FetchDescriptor<MediaItem>())
        #expect(items.count == 1)
        #expect(items.first?.id != item.id)
        #expect(fixture.service.lastImportErrors.isEmpty)
        #expect(fixture.service.pendingFileRemovals.isEmpty)
    }

    @Test func mediaInfoResolvesTheBookmarkOutsideTheMainThread() async throws {
        let recorder = BookmarkResolutionRecorder()
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)

        let details = await fixture.service.loadMediaInfo(for: item)

        let path = details.fileRows.first { $0.id == "filePath" }?.value
        #expect(path == fixture.mediaDirectory.appendingPathComponent(item.fileName).path)
        #expect(details.fileRows.contains { $0.id == "fileSize" })
        #expect(recorder.mainThreadCount == 0)
        #expect(recorder.workerCount == 1)
    }
}

@MainActor
private struct BookmarkFixture {
    let directory: URL
    let mediaDirectory: URL
    let container: ModelContainer
    let service: LibraryService
    var context: ModelContext { container.mainContext }

    init(recorder: BookmarkResolutionRecorder) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        mediaDirectory = directory.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        service = LibraryService(mediaDirectoryURL: mediaDirectory, resolveBookmark: recorder.resolve)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func makeAudio(named name: String, frameCount: AVAudioFrameCount) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        samples.update(repeating: 0.1, count: Int(frameCount))
        try file.write(from: buffer)
        return url
    }

    /// Inserts an item without a fingerprint, like one imported before fingerprints were recorded.
    func insertItem(copying source: URL) throws -> MediaItem {
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        try FileManager.default.copyItem(at: source, to: mediaDirectory.appendingPathComponent(fileName))
        let item = MediaItem(
            id: id, title: "Track", duration: 0.1, isVideo: false, bookmarkData: Data([0xFF]), fileName: fileName
        )
        context.insert(item)
        try context.save()
        return item
    }
}

nonisolated private final class BookmarkResolutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchGroup()
    private var counts = (mainThread: 0, worker: 0)
    private var isBlocking: Bool
    private let blockedCallCount: Int

    /// Blocks the first `blockedCallCount` resolutions until `release()` when `blocksUntilReleased` is set.
    init(blocksUntilReleased: Bool = false, blockedCallCount: Int = .max) {
        isBlocking = blocksUntilReleased
        self.blockedCallCount = blockedCallCount
        if blocksUntilReleased { gate.enter() }
    }

    var mainThreadCount: Int { lock.withLock { counts.mainThread } }
    var workerCount: Int { lock.withLock { counts.worker } }

    func resolve(_ bookmarkData: Data, _ fallbackURL: URL) -> URL {
        let callIndex = lock.withLock {
            if Thread.isMainThread { counts.mainThread += 1 } else { counts.worker += 1 }
            return counts.mainThread + counts.worker
        }
        if callIndex <= blockedCallCount { gate.wait() }
        return fallbackURL
    }

    func release() {
        let shouldLeave = lock.withLock {
            defer { isBlocking = false }
            return isBlocking
        }
        if shouldLeave { gate.leave() }
    }
}

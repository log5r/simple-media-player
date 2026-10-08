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
        let recorder = BookmarkResolutionRecorder { _ in true }
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

    @Test func mp4ReaderStopsWhenItsTaskIsCancelled() async throws {
        let fixture = Bundle.allBundles.compactMap({
            $0.url(forResource: "fragmented-video", withExtension: "mp4")
        }).first ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fragmented-video.mp4")
        _ = try MP4MetadataReader.read(from: fixture)

        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MP4TitleReader.title(in: fixture)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func deleteRemovesTheFileInAWorkerBeforeTheItem() async throws {
        let recorder = BookmarkResolutionRecorder { $0 == 1 }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        defer { recorder.release() }

        let deletion = Task { await fixture.service.delete(item, from: fixture.context) }
        try await waitUntil { recorder.workerCount == 1 }
        // The item stays until its file is gone, and a repeated request does not start another removal.
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 1)
        await fixture.service.delete(item, from: fixture.context)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 1)
        recorder.release()
        await deletion.value

        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(recorder.mainThreadCount == 0)
        #expect(recorder.workerCount == 1)
    }

    @Test func importDuringADeletionDoesNotTreatTheItemsFileAsADuplicate() async throws {
        let recorder = BookmarkResolutionRecorder { $0 == 1 }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        item.importFingerprint = try MediaImportFingerprint.read(from: source)
        try fixture.context.save()
        defer { recorder.release() }

        let deletion = Task { await fixture.service.delete(item, from: fixture.context) }
        try await waitUntil { recorder.workerCount == 1 }
        // The item and its file still exist while the removal is blocked.
        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [item])
        recorder.release()
        await deletion.value

        let items = try fixture.context.fetch(FetchDescriptor<MediaItem>())
        #expect(items.count == 1)
        #expect(items.first?.id != item.id)
        #expect(fixture.service.lastImportErrors.isEmpty)
    }

    @Test(arguments: [true, false])
    func deletionDuringTheDuplicateProbeDoesNotSuppressTheImport(hasFingerprint: Bool) async throws {
        // Call 1 is the duplicate probe (or the legacy size grouping); call 2 is the file removal.
        let recorder = BookmarkResolutionRecorder { $0 <= 2 }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let itemFile = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        if hasFingerprint {
            item.importFingerprint = try MediaImportFingerprint.read(from: source)
            try fixture.context.save()
        }
        defer { recorder.release() }

        let importTask = Task {
            await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [item])
        }
        try await waitUntil { recorder.workerCount == 1 }
        let deletion = Task { await fixture.service.delete(item, from: fixture.context) }
        try await waitUntil { recorder.workerCount == 2 }
        // The probe finishes while the deleted item's file still exists.
        recorder.release(call: 1)
        await importTask.value
        recorder.release(call: 2)
        await deletion.value

        let items = try fixture.context.fetch(FetchDescriptor<MediaItem>())
        #expect(items.count == 1)
        #expect(items.first?.id != item.id)
        #expect(fixture.service.lastImportErrors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: itemFile.path) == false)
        let imported = try #require(items.first)
        let importedFile = fixture.mediaDirectory.appendingPathComponent(imported.fileName)
        #expect(FileManager.default.fileExists(atPath: importedFile.path))
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

private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while condition() == false && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
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
    private let blocks: @Sendable (Int) -> Bool
    private var counts = (mainThread: 0, worker: 0)
    private var gates: [Int: DispatchSemaphore] = [:]
    private var releasedCalls: Set<Int> = []
    private var isReleased = false

    /// Blocks each resolution whose 1-based call number satisfies `blocks` until it is released.
    init(blocking blocks: @escaping @Sendable (Int) -> Bool = { _ in false }) {
        self.blocks = blocks
    }

    var mainThreadCount: Int { lock.withLock { counts.mainThread } }
    var workerCount: Int { lock.withLock { counts.worker } }

    func resolve(_ bookmarkData: Data, _ fallbackURL: URL) -> URL {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            if Thread.isMainThread { counts.mainThread += 1 } else { counts.worker += 1 }
            let call = counts.mainThread + counts.worker
            guard blocks(call), isReleased == false, releasedCalls.contains(call) == false else { return nil }
            let gate = DispatchSemaphore(value: 0)
            gates[call] = gate
            return gate
        }
        gate?.wait()
        return fallbackURL
    }

    func release(call: Int) {
        let gate = lock.withLock {
            releasedCalls.insert(call)
            return gates.removeValue(forKey: call)
        }
        gate?.signal()
    }

    func release() {
        let pending = lock.withLock {
            isReleased = true
            defer { gates = [:] }
            return Array(gates.values)
        }
        pending.forEach { $0.signal() }
    }
}

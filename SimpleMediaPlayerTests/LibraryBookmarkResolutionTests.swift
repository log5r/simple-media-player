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

        await recorder.waitForCalls(1)
        task.cancel()
        recorder.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.workerCount <= LibraryService.exportPlanConcurrency * 2)
        #expect(recorder.mainThreadCount == 0)
    }

    @Test func cancelledExportPlanReturnsWhileResolutionIsStillBlocked() async throws {
        let recorder = BookmarkResolutionRecorder { _ in true }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let items = [try fixture.insertItem(copying: source)]
        let task = Task { try await fixture.service.makeExportPlan(for: items) }
        defer { recorder.release() }

        await recorder.waitForCalls(1)
        let start = ContinuousClock.now
        task.cancel()

        // The resolution stays blocked until the end of the test, so only the cancellation can end the wait.
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
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

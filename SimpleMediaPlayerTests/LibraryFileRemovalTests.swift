import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryFileRemovalTests {
    @Test func deleteRemovesTheItemImmediatelyAndJournalsTheFileRemoval() async throws {
        let recorder = BookmarkResolutionRecorder { $0 == 1 }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let itemID = item.id
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        defer { recorder.release() }

        let removal = fixture.service.delete(item, from: fixture.context)

        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
        #expect(fixture.service.delete(item, from: fixture.context) == nil)
        await recorder.waitForCalls(1)
        #expect(fixture.journal.entries(in: fixture.mediaDirectory).map(\.id) == [itemID])
        recorder.release()
        await removal?.value
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(fixture.journal.entries(in: fixture.mediaDirectory).isEmpty)
        #expect(recorder.mainThreadCount == 0)
        #expect(recorder.workerCount == 1)
    }

    @Test func interruptedFileRemovalResumesAtTheNextLaunch() async throws {
        let recorder = BookmarkResolutionRecorder()
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: item.id, bookmarkData: item.bookmarkData, fallbackPath: fileURL.path
        ))
        let otherDirectory = fixture.directory.appendingPathComponent("OtherMedia")
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let otherFile = otherDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: source, to: otherFile)
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: UUID(), bookmarkData: Data([0xFF]), fallbackPath: otherFile.path
        ))

        let relaunched = LibraryService(
            mediaDirectoryURL: fixture.mediaDirectory,
            resolveBookmark: recorder.resolve,
            removalJournal: fixture.journal
        )
        await relaunched.resumePendingFileRemovals().value

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(fixture.journal.entries(in: fixture.mediaDirectory).isEmpty)
        // Entries of another media directory belong to another service.
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
        #expect(fixture.journal.entries(in: otherDirectory).count == 1)
        #expect(recorder.mainThreadCount == 0)
    }

    @Test func failedFileRemovalStaysJournaledUntilItSucceeds() async throws {
        let recorder = BookmarkResolutionRecorder()
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let itemID = item.id
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        let cacheEntries = try writeCacheEntries(for: fileURL)
        defer { cacheEntries.forEach { try? FileManager.default.removeItem(at: $0) } }
        let missing = PendingFileRemovalJournal.Entry(
            id: UUID(), bookmarkData: Data([0xFF]),
            fallbackPath: fixture.mediaDirectory.appendingPathComponent("\(UUID().uuidString).wav").path
        )
        fixture.journal.add(missing)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.mediaDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.mediaDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: attributes[.posixPermissions] ?? 0o755], ofItemAtPath: fixture.mediaDirectory.path
            )
        }

        await fixture.service.delete(item, from: fixture.context)?.value
        await fixture.service.resumePendingFileRemovals().value

        // The item is gone, but its file could not be removed, so the entry remains for a later retry.
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(fixture.journal.entries(in: fixture.mediaDirectory).map(\.id) == [itemID])
        // The retry reads the keys again, so the entries stay with the file until then.
        #expect(cacheEntries.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.mediaDirectory.path)
        await fixture.service.resumePendingFileRemovals().value

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(fixture.journal.entries(in: fixture.mediaDirectory).isEmpty)
        #expect(cacheEntries.allSatisfy { FileManager.default.fileExists(atPath: $0.path) == false })
    }

    /// The loudness and analysis entries are keyed by the removed file's path and attributes, so nothing could
    /// find them again; the caches have no entry limit, so they would stay until the system purges Caches.
    @Test(arguments: [false, true])
    func removingAFileRemovesItsCacheEntries(resumed: Bool) async throws {
        let recorder = BookmarkResolutionRecorder()
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        // The service removes entries from the default directories, as it does in the app.
        let cacheEntries = try writeCacheEntries(for: fileURL)
        defer { cacheEntries.forEach { try? FileManager.default.removeItem(at: $0) } }

        if resumed {
            fixture.journal.add(PendingFileRemovalJournal.Entry(
                id: item.id, bookmarkData: item.bookmarkData, fallbackPath: fileURL.path
            ))
            let relaunched = LibraryService(
                mediaDirectoryURL: fixture.mediaDirectory,
                resolveBookmark: recorder.resolve,
                removalJournal: fixture.journal
            )
            await relaunched.resumePendingFileRemovals().value
        } else {
            await fixture.service.delete(item, from: fixture.context)?.value
        }

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(cacheEntries.allSatisfy { FileManager.default.fileExists(atPath: $0.path) == false })
    }

    private func writeCacheEntries(for url: URL) throws -> [URL] {
        let loudness = try #require(AudioLoudnessCache.entryURL(for: url))
        AudioLoudnessCache.write(3, at: loudness)
        let analysis = try #require(MusicAnalysisCache.entryURL(for: url))
        MusicAnalysisCache.write(MusicAnalysis(duration: 8, bpm: 128), at: analysis)
        #expect([loudness, analysis].allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        return [loudness, analysis]
    }

    @Test func staleSnapshotDoesNotTreatADeletedItemsPendingFileAsADuplicate() async throws {
        let recorder = BookmarkResolutionRecorder { $0 == 1 }
        let fixture = try BookmarkFixture(recorder: recorder)
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let itemID = item.id
        item.importFingerprint = try MediaImportFingerprint.read(from: source)
        try fixture.context.save()
        defer { recorder.release() }

        let removal = fixture.service.delete(item, from: fixture.context)
        await recorder.waitForCalls(1)
        // The caller's snapshot still lists the deleted item while its file removal is blocked.
        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [item])
        recorder.release()
        await removal?.value

        let items = try fixture.context.fetch(FetchDescriptor<MediaItem>())
        #expect(items.count == 1)
        #expect(items.first?.id != itemID)
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
        await recorder.waitForCalls(1)
        let removal = fixture.service.delete(item, from: fixture.context)
        await recorder.waitForCalls(2)
        // The probe finishes while the deleted item's file still exists.
        recorder.release(call: 1)
        await importTask.value
        recorder.release(call: 2)
        await removal?.value

        let items = try fixture.context.fetch(FetchDescriptor<MediaItem>())
        #expect(items.count == 1)
        #expect(items.first?.id != item.id)
        #expect(fixture.service.lastImportErrors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: itemFile.path) == false)
        let imported = try #require(items.first)
        let importedFile = fixture.mediaDirectory.appendingPathComponent(imported.fileName)
        #expect(FileManager.default.fileExists(atPath: importedFile.path))
    }
}

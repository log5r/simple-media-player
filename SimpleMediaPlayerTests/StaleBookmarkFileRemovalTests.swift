import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

/// A journaled removal still reaches a file in the current media directory when the entry's bookmark resolves
/// to a location that no longer exists, as after iOS moves the app's container.
@MainActor
struct StaleBookmarkFileRemovalTests {
    @Test func bookmarkResolvingToTheLocationBeforeAContainerMoveStillRemovesTheFileByName() async throws {
        let fixture = try BookmarkFixture(recorder: BookmarkResolutionRecorder())
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        let cacheEntries = try writeDerivedCacheEntries(for: fileURL)
        defer { cacheEntries.forEach { try? FileManager.default.removeItem(at: $0) } }
        // The bookmark still resolves to where the file was before iOS moved the app's container.
        let oldLocation = fixture.directory.appendingPathComponent("OldContainer/Media/\(item.fileName)")
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: item.id, bookmarkData: Data([0x01]), fileName: item.fileName, libraryID: fixture.service.libraryID
        ))

        let relaunched = LibraryService(
            mediaDirectoryURL: fixture.mediaDirectory,
            resolveBookmark: { _, _ in oldLocation },
            removalJournal: fixture.journal
        )
        await relaunched.resumePendingFileRemovals().value

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(fixture.pendingRemovals().isEmpty)
        #expect(cacheEntries.allSatisfy { FileManager.default.fileExists(atPath: $0.path) == false })
    }

    @Test func earlierFormatEntryInTheMediaDirectoryIsRemovedThereWhenItsBookmarkIsStale() async throws {
        let fixture = try BookmarkFixture(recorder: BookmarkResolutionRecorder())
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        // A previous release journaled the current path, but the bookmark still names the old container.
        let oldLocation = fixture.directory.appendingPathComponent("OldContainer/Media/\(item.fileName)")
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: item.id, bookmarkData: Data([0x01]), location: .legacyPath(fileURL.path)
        ))

        let relaunched = LibraryService(
            mediaDirectoryURL: fixture.mediaDirectory,
            resolveBookmark: { _, _ in oldLocation },
            removalJournal: fixture.journal
        )
        await relaunched.resumePendingFileRemovals().value

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(fixture.journal.entries(forLibrary: relaunched.libraryID, mediaDirectory: fixture.mediaDirectory)
            .isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func earlierFormatEntryWrittenThroughAnotherNameOfTheMediaDirectoryIsRemovedThere() async throws {
        let fixture = try BookmarkFixture(recorder: BookmarkResolutionRecorder())
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        // Like `/var` and `/private/var`, a symbolic link gives the media directory a second name.
        let alias = fixture.directory.appendingPathComponent("MediaAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.mediaDirectory)
        let aliasedURL = alias.appendingPathComponent(item.fileName)
        // The caches key the file by its path as written, so each name has its own entries.
        let entries = try writeDerivedCacheEntries(for: fileURL) + writeDerivedCacheEntries(for: aliasedURL)
        let decodedCaches = try [fileURL, aliasedURL].map { try writeDecodedCache(for: $0) }
        defer { (entries + decodedCaches).forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(Set(entries).count == 4)
        #expect(Set(decodedCaches).count == 2)
        let oldLocation = fixture.directory.appendingPathComponent("OldContainer/Media/\(item.fileName)")
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: item.id, bookmarkData: Data([0x01]), location: .legacyPath(aliasedURL.path)
        ))

        let relaunched = LibraryService(
            mediaDirectoryURL: fixture.mediaDirectory,
            resolveBookmark: { _, _ in oldLocation },
            removalJournal: fixture.journal
        )
        await relaunched.resumePendingFileRemovals().value

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(fixture.journal.entries(forLibrary: relaunched.libraryID, mediaDirectory: fixture.mediaDirectory)
            .isEmpty)
        #expect(fixture.journal.legacyEntries(outside: fixture.mediaDirectory).isEmpty)
        #expect(entries.allSatisfy { FileManager.default.fileExists(atPath: $0.path) == false })
        // The decoded caches are removed on the cache's own maintenance queue.
        #expect(await waitUntilRemoved(decodedCaches))
    }

    @Test(arguments: [false, true])
    func earlierFormatEntryIsNotReachedThroughANameThatChangesBeforeTheRemoval(repointed: Bool) async throws {
        let fixture = try BookmarkFixture(recorder: BookmarkResolutionRecorder())
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        let alias = fixture.directory.appendingPathComponent("MediaAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.mediaDirectory)
        let elsewhere = fixture.directory.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let sameNamedFile = elsewhere.appendingPathComponent(item.fileName)
        try Data("another library".utf8).write(to: sameNamedFile)
        let oldLocation = fixture.directory.appendingPathComponent("OldContainer/Media/\(item.fileName)")
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: item.id, bookmarkData: Data([0x01]),
            location: .legacyPath(alias.appendingPathComponent(item.fileName).path)
        ))

        // The name of the media directory the entry was written with is removed or repointed after its check.
        let relaunched = LibraryService(
            mediaDirectoryURL: fixture.mediaDirectory,
            resolveBookmark: { _, _ in
                try? FileManager.default.removeItem(at: alias)
                if repointed { try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: elsewhere) }
                return oldLocation
            },
            removalJournal: fixture.journal
        )
        await relaunched.resumePendingFileRemovals().value

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: sameNamedFile.path))
        #expect(fixture.journal.entries(forLibrary: relaunched.libraryID, mediaDirectory: fixture.mediaDirectory)
            .isEmpty)
    }

    @Test func uncheckedEarlierFormatPathIsNeitherRemovedNorForgotten() async throws {
        let fixture = try BookmarkFixture(recorder: BookmarkResolutionRecorder())
        defer { fixture.remove() }
        let outsideDirectory = fixture.directory.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideFile = outsideDirectory.appendingPathComponent("song.wav")
        try Data("audio".utf8).write(to: outsideFile)
        let oldLocation = fixture.directory.appendingPathComponent("OldContainer/Media/song.wav")
        let removal = PendingFileRemovalJournal.Entry(
            id: UUID(), bookmarkData: Data([0x01]), location: .legacyPath(outsideFile.path)
        )
        fixture.journal.add(removal)
        let service = LibraryService(
            mediaDirectoryURL: fixture.mediaDirectory,
            resolveBookmark: { _, _ in oldLocation },
            removalJournal: fixture.journal
        )

        // Only selecting the entries checks an earlier-format path, so a path handed over unchecked is left.
        await FileSystemWorkQueue.run { service.removeFile(for: removal) }

        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
        #expect(fixture.journal.legacyEntries(outside: fixture.mediaDirectory).map(\.id) == [removal.id])
    }
}

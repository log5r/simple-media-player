import Foundation
import Testing
@testable import SimpleMediaPlayer

/// A journaled file can be named through a symbolic link, as `/var` names `/private/var`. The removal reaches
/// the file only through a checked name, and removes the caches keyed by each of its names.
@MainActor
struct AliasedFileRemovalTests {
    @Test func linkRepointedAfterTheEntryIsSelectedCannotSendTheRemovalOutside() async throws {
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
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: item.id, bookmarkData: Data([0x01]),
            location: .legacyPath(alias.appendingPathComponent(item.fileName).path)
        ))
        // The bookmark does not resolve, so the removal falls back to the location it is given.
        let service = LibraryService(
            mediaDirectoryURL: fixture.mediaDirectory, resolveBookmark: { _, fallback in fallback },
            removalJournal: fixture.journal
        )

        let selected = fixture.journal.entries(forLibrary: service.libraryID, mediaDirectory: fixture.mediaDirectory)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: elsewhere)
        await FileSystemWorkQueue.run { selected.forEach(service.removeFile(for:)) }

        #expect(selected.map(\.id) == [item.id])
        #expect(FileManager.default.fileExists(atPath: sameNamedFile.path))
        // The library's file is removed with its entry; an entry is never dropped while the file stays.
        let remaining = fixture.journal.entries(forLibrary: service.libraryID, mediaDirectory: fixture.mediaDirectory)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(remaining.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func bookmarkResolvingThroughALinkRemovesTheCachesOfEveryName(earlierFormat: Bool) async throws {
        let fixture = try BookmarkFixture(recorder: BookmarkResolutionRecorder())
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav", frameCount: 4_410)
        let item = try fixture.insertItem(copying: source)
        let fileURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        let alias = fixture.directory.appendingPathComponent("MediaAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.mediaDirectory)
        let aliasedURL = alias.appendingPathComponent(item.fileName)
        let entries = try writeDerivedCacheEntries(for: fileURL) + writeDerivedCacheEntries(for: aliasedURL)
        let decodedCaches = try [fileURL, aliasedURL].map { try writeDecodedCache(for: $0) }
        defer { (entries + decodedCaches).forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(Set(entries).count == 4)
        #expect(Set(decodedCaches).count == 2)
        let service = LibraryService(
            mediaDirectoryURL: fixture.mediaDirectory, resolveBookmark: { _, _ in aliasedURL },
            removalJournal: fixture.journal
        )
        fixture.journal.add(earlierFormat
            ? PendingFileRemovalJournal.Entry(
                id: item.id, bookmarkData: Data([0x01]), location: .legacyPath(aliasedURL.path)
            )
            : PendingFileRemovalJournal.Entry(
                id: item.id, bookmarkData: Data([0x01]), fileName: item.fileName, libraryID: service.libraryID
            ))

        // The bookmark resolves to the existing file through the link, so the first location removes it.
        await service.resumePendingFileRemovals().value

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(fixture.journal.entries(forLibrary: service.libraryID, mediaDirectory: fixture.mediaDirectory).isEmpty)
        #expect(entries.allSatisfy { FileManager.default.fileExists(atPath: $0.path) == false })
        #expect(await waitUntilRemoved(decodedCaches))
    }
}

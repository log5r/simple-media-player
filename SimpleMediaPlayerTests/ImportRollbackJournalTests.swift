import Foundation
import Testing
@testable import SimpleMediaPlayer

/// A managed copy the import could not remove stays journaled, by name within its library, until a retry
/// removes it, even after the media directory moves as iOS moves the app's container.
@MainActor
struct ImportRollbackJournalTests {
    @Test func rollbackThatCannotRemoveTheCopyStaysJournaledUntilTheRetry() async throws {
        let fixture = try makeFixtureLosingSearchPermission()
        defer { fixture.remove() }
        defer { restorePermissions(of: fixture.mediaDirectory) }
        let source = try fixture.makeAudio(named: "song.wav")

        let summary = await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])

        #expect(summary.createdCount == 0)
        #expect(fixture.service.lastImportErrors.count == 1)
        let entry = try #require(fixture.pendingRemovals().first)
        restorePermissions(of: fixture.mediaDirectory)
        #expect(try fixture.managedFiles().map(\.lastPathComponent) == [fileName(of: entry)])

        await fixture.service.resumePendingFileRemovals().value

        #expect(try fixture.managedFiles().isEmpty)
        #expect(fixture.pendingRemovals().isEmpty)
    }

    @Test func journaledCopyIsRemovedAfterTheMediaDirectoryMoves() async throws {
        let fixture = try makeFixtureLosingSearchPermission()
        defer { fixture.remove() }
        defer { restorePermissions(of: fixture.mediaDirectory) }
        let source = try fixture.makeAudio(named: "song.wav")
        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])
        let entry = try #require(fixture.pendingRemovals().first)
        restorePermissions(of: fixture.mediaDirectory)

        let moved = fixture.directory.appendingPathComponent("MovedContainer/Media")
        try FileManager.default.createDirectory(
            at: moved.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: fixture.mediaDirectory, to: moved)
        // Another library's entry names a file in the moved directory, and earlier-format entries keep
        // their absolute paths: one inside the moved directory and one left in the old location.
        let otherLibraryFile = try makeFile(named: "other-library.wav", in: moved)
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: UUID(), bookmarkData: Data(), fileName: otherLibraryFile.lastPathComponent, libraryID: "other-library"
        ))
        let legacyFile = try makeFile(named: "legacy.wav", in: moved)
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: UUID(), bookmarkData: Data([0xFF]), location: .legacyPath(legacyFile.path)
        ))
        let staleLegacyID = UUID()
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: staleLegacyID, bookmarkData: Data([0xFF]),
            location: .legacyPath(fixture.mediaDirectory.appendingPathComponent("stale.wav").path)
        ))

        let relaunched = LibraryService(
            mediaDirectoryURL: moved, removalJournal: fixture.journal, libraryID: fixture.libraryID
        )
        #expect(relaunched.libraryID == fixture.service.libraryID)
        await relaunched.resumePendingFileRemovals().value

        let remaining = try FileManager.default.contentsOfDirectory(atPath: moved.path)
        #expect(remaining.contains(fileName(of: entry)) == false)
        #expect(remaining.contains(legacyFile.lastPathComponent) == false)
        #expect(remaining == [otherLibraryFile.lastPathComponent])
        #expect(fixture.journal.entries(forLibrary: fixture.libraryID, mediaDirectory: moved).isEmpty)
        #expect(fixture.journal.entries(forLibrary: "other-library", mediaDirectory: moved).count == 1)
        #expect(fixture.journal.entries(forLibrary: fixture.libraryID, mediaDirectory: fixture.mediaDirectory)
            .map(\.id) == [staleLegacyID])
    }

    @Test func earlierFormatEntryIsFoundThroughItsBookmarkAfterTheMediaDirectoryMoves() async throws {
        let fixture = try InspectionFixture(recorder: ImportOperationRecorder())
        defer { fixture.remove() }
        // Entries a previous release wrote: absolute paths with the files' real bookmarks.
        let pending = try makeFile(named: "\(UUID().uuidString).wav", in: fixture.mediaDirectory)
        try addEarlierFormatEntry(for: pending, to: fixture.journal)
        let otherDirectory = fixture.directory.appendingPathComponent("OtherLibrary/Media")
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let otherFile = try makeFile(named: "other.wav", in: otherDirectory)
        let otherID = try addEarlierFormatEntry(for: otherFile, to: fixture.journal)
        let unresolvableID = UUID()
        fixture.journal.add(PendingFileRemovalJournal.Entry(
            id: unresolvableID, bookmarkData: Data([0xFF]),
            location: .legacyPath(fixture.mediaDirectory.appendingPathComponent("gone.wav").path)
        ))
        let moved = fixture.directory.appendingPathComponent("MovedContainer/Media")
        try FileManager.default.createDirectory(
            at: moved.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: fixture.mediaDirectory, to: moved)

        let relaunched = LibraryService(
            mediaDirectoryURL: moved, removalJournal: fixture.journal, libraryID: fixture.libraryID
        )
        await relaunched.resumePendingFileRemovals().value

        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        #expect(fixture.journal.entries(forLibrary: fixture.libraryID, mediaDirectory: moved).isEmpty)
        // Another library's file, and an entry whose bookmark cannot tell, are left for their owners.
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
        #expect(fixture.journal.entries(forLibrary: "other", mediaDirectory: otherDirectory).map(\.id) == [otherID])
        #expect(Set(fixture.journal.legacyEntries(outside: moved).map(\.id)) == [otherID, unresolvableID])
    }

    @Test func defaultLibraryIDsSeparateOverridingDirectoriesButNotTheAppLibrary() {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstID = LibraryService(mediaDirectoryURL: first).libraryID
        #expect(LibraryService(mediaDirectoryURL: first).libraryID == firstID)
        #expect(LibraryService(mediaDirectoryURL: second).libraryID != firstID)
        #expect(LibraryService().libraryID == LibraryService().libraryID)
        #expect(LibraryService(mediaDirectoryURL: first, libraryID: "named").libraryID == "named")
    }

    @Test func onlyAMissingFileCountsAsRemoved() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let removalError = try #require(throws: (any Error).self) { try FileManager.default.removeItem(at: missing) }
        #expect(LibraryService.isMissingFileError(removalError))
        #expect(LibraryService.isMissingFileError(CocoaError(.fileNoSuchFile)))
        #expect(LibraryService.isMissingFileError(POSIXError(.ENOENT)))
        #expect(LibraryService.isMissingFileError(CocoaError(.fileReadNoPermission)) == false)
        #expect(LibraryService.isMissingFileError(CocoaError(
            .fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)]
        )) == false)
        #expect(LibraryService.isMissingFileError(POSIXError(.EACCES)) == false)
    }

    /// The bookmark step takes the media directory's search permission and fails, so the rollback can
    /// neither remove the copy nor check whether it exists.
    private func makeFixtureLosingSearchPermission() throws -> InspectionFixture {
        try InspectionFixture(recorder: ImportOperationRecorder(), beforeBookmark: { copiedURL in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: copiedURL.deletingLastPathComponent().path
            )
            throw CocoaError(.fileWriteUnknown)
        })
    }

    private func fileName(of entry: PendingFileRemovalJournal.Entry) -> String {
        switch entry.location {
        case let .managed(fileName, _): fileName
        case let .legacyPath(path): URL(fileURLWithPath: path).lastPathComponent
        }
    }

    @discardableResult
    private func addEarlierFormatEntry(for file: URL, to journal: PendingFileRemovalJournal) throws -> UUID {
        let id = UUID()
        journal.add(PendingFileRemovalJournal.Entry(
            id: id, bookmarkData: try ImportFileOperations.managedFileBookmark(for: file),
            location: .legacyPath(file.path)
        ))
        return id
    }

    private func makeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func restorePermissions(of directory: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
}

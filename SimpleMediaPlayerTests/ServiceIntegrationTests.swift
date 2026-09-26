import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MediaExportServiceIntegrationTests {
    @Test func emptyExportReturnsAnErrorWithoutStartingProgress() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let service = LibraryService(mediaDirectoryURL: sandbox.url.appendingPathComponent("Media"))

        let result = await service.export(files: [], to: sandbox.url)

        #expect(result.exportedCount == 0)
        #expect(result.errors.count == 1)
        #expect(service.isExporting == false)
        #expect(service.exportProgress == 0)
        #expect(service.exportCompletedFileCount == 0)
        #expect(service.exportTotalFileCount == 0)
    }

    @Test func exportCopiesFilesIntoSanitizedAlbumAndUsesUniqueNames() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let sourceDirectory = try sandbox.createDirectory(named: "Source")
        let destinationDirectory = try sandbox.createDirectory(named: "Destination")
        let firstSource = sourceDirectory.appendingPathComponent("first.mp3")
        let secondSource = sourceDirectory.appendingPathComponent("second.mp3")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let existingAlbumDirectory = destinationDirectory.appendingPathComponent("Album Name")
        try FileManager.default.createDirectory(at: existingAlbumDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingAlbumDirectory.appendingPathComponent("Track Name.mp3"))

        let service = LibraryService(mediaDirectoryURL: sandbox.url.appendingPathComponent("Media"))
        let files = [
            exportFile(sourceURL: firstSource, album: "Album/Name", title: "Track:Name", originalName: "first.mp3"),
            exportFile(sourceURL: secondSource, album: "Album/Name", title: "Track:Name", originalName: "second.mp3")
        ]

        let result = await service.export(files: files, to: destinationDirectory)

        #expect(result.exportedCount == 2)
        #expect(result.errors.isEmpty)
        #expect(
            try Data(contentsOf: existingAlbumDirectory.appendingPathComponent("Track Name_2.mp3"))
                == Data("first".utf8)
        )
        #expect(
            try Data(contentsOf: existingAlbumDirectory.appendingPathComponent("Track Name_3.mp3"))
                == Data("second".utf8)
        )
        #expect(service.isExporting == false)
        #expect(service.exportProgress == 1)
        #expect(service.exportCompletedFileCount == 2)
        #expect(service.exportTotalFileCount == 2)
        #expect(service.currentExportFileName == nil)
        #expect(service.lastExportErrors.isEmpty)
    }

    @Test func exportContinuesAfterACopyFailureAndPublishesTheError() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let destinationDirectory = try sandbox.createDirectory(named: "Destination")
        let validSource = sandbox.url.appendingPathComponent("valid.aiff")
        try Data("audio".utf8).write(to: validSource)
        let missingSource = sandbox.url.appendingPathComponent("missing.aiff")
        let service = LibraryService(mediaDirectoryURL: sandbox.url.appendingPathComponent("Media"))

        let result = await service.export(files: [
            exportFile(sourceURL: missingSource, album: "Album", title: "Missing", originalName: "missing.aiff"),
            exportFile(sourceURL: validSource, album: "Album", title: "Valid", originalName: "valid.aiff")
        ], to: destinationDirectory)

        #expect(result.exportedCount == 1)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].hasPrefix("missing.aiff:"))
        #expect(
            FileManager.default.fileExists(atPath: destinationDirectory.appendingPathComponent("Album/Valid.aiff").path)
        )
        #expect(service.lastExportErrors == result.errors)
        #expect(service.exportProgress == 1)
        #expect(service.exportCompletedFileCount == 2)
    }

    @Test func exportPlanUsesFallbackURLAndNormalizesUnknownAlbum() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let mediaDirectory = try sandbox.createDirectory(named: "Media")
        let mediaURL = mediaDirectory.appendingPathComponent("untitled.bin")
        try Data("payload".utf8).write(to: mediaURL)
        let item = MediaItem(
            title: "Model Title",
            album: "Unknown Album",
            duration: 1,
            isVideo: false,
            bookmarkData: Data([0xFF]),
            fileName: mediaURL.lastPathComponent
        )
        let service = LibraryService(mediaDirectoryURL: mediaDirectory)

        let plan = await service.makeExportPlan(for: [item])

        let draft = try #require(plan.files.first)
        #expect(plan.files.count == 1)
        #expect(plan.preparationErrors.isEmpty)
        #expect(draft.sourceURL == mediaURL)
        #expect(draft.albumName == MediaExportNaming.unnamedAlbumName)
        #expect(draft.embeddedTitle == nil)
        #expect(draft.fileExtension == "bin")
        #expect(draft.originalFileName == "untitled.bin")
    }

    private func exportFile(
        sourceURL: URL,
        album: String,
        title: String,
        originalName: String
    ) -> MediaExportFile {
        MediaExportFile(
            id: UUID(),
            sourceURL: sourceURL,
            albumName: album,
            title: title,
            fileExtension: sourceURL.pathExtension,
            originalFileName: originalName
        )
    }
}

@MainActor
struct LibraryServicePersistenceTests {
    @Test func emptyImportLeavesExistingProgressStateUnchanged() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let fixture = try makePersistenceFixture(mediaDirectory: sandbox.url.appendingPathComponent("Media"))
        fixture.service.importProgress = 0.25

        await fixture.service.importFiles(from: [], into: fixture.context, existingItems: [])

        #expect(fixture.service.isImporting == false)
        #expect(fixture.service.importProgress == 0.25)
        #expect(fixture.service.importTotalFileCount == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
    }

    @Test func failedImportCompletesProgressAndReportsTheFileError() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let fixture = try makePersistenceFixture(mediaDirectory: sandbox.url.appendingPathComponent("Media"))
        let missingURL = sandbox.url.appendingPathComponent("missing.wav")

        await fixture.service.importFiles(from: [missingURL], into: fixture.context, existingItems: [])

        #expect(fixture.service.isImporting == false)
        #expect(fixture.service.importProgress == 1)
        #expect(fixture.service.importCompletedFileCount == 1)
        #expect(fixture.service.importTotalFileCount == 1)
        #expect(fixture.service.currentImportFileName == nil)
        #expect(fixture.service.lastImportErrors.count == 1)
        #expect(fixture.service.lastImportErrors[0].hasPrefix("missing.wav:"))
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
    }

    @Test func deleteRemovesThePersistedItemAndItsResolvedFile() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let mediaDirectory = try sandbox.createDirectory(named: "Media")
        let fixture = try makePersistenceFixture(mediaDirectory: mediaDirectory)
        let fileURL = mediaDirectory.appendingPathComponent("delete-me.mp3")
        try Data("audio".utf8).write(to: fileURL)
        let item = makeItem(bookmarkData: Data([0xFF]), fileName: fileURL.lastPathComponent)
        fixture.context.insert(item)
        try fixture.context.save()

        fixture.service.delete(item, from: fixture.context)

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
    }

    @Test func transformedCopyIsCopiedAndPersistsInheritedMetadata() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let mediaDirectory = try sandbox.createDirectory(named: "Media")
        let fixture = try makePersistenceFixture(mediaDirectory: mediaDirectory)
        let renderedURL = sandbox.url.appendingPathComponent("rendered.wav")
        try Data("rendered audio".utf8).write(to: renderedURL)
        let source = makeItem(
            title: "Source",
            artist: "Artist",
            album: "Album",
            genre: "Genre",
            bookmarkData: Data([0xFF]),
            fileName: "source.mp3"
        )
        source.year = "2026"
        source.trackNumber = "3/12"
        source.comment = "Comment"
        source.albumArtist = "Album Artist"
        source.composer = "Composer"
        source.discNumber = "1/2"
        source.isCompilation = true
        source.lyricsRaw = "Lyrics"
        source.artworkData = Data([1, 2, 3])

        let copy = try await fixture.service.registerTransformedCopy(
            of: source,
            renderedFileURL: renderedURL,
            title: "Rendered",
            duration: .infinity,
            in: fixture.context
        )

        #expect(copy.title == "Rendered")
        #expect(copy.artist == "Artist")
        #expect(copy.album == "Album")
        #expect(copy.genre == "Genre")
        #expect(copy.year == "2026")
        #expect(copy.trackNumber == "3/12")
        #expect(copy.comment == "Comment")
        #expect(copy.albumArtist == "Album Artist")
        #expect(copy.composer == "Composer")
        #expect(copy.discNumber == "1/2")
        #expect(copy.isCompilation)
        #expect(copy.lyricsRaw == "Lyrics")
        #expect(copy.artworkData == Data([1, 2, 3]))
        #expect(copy.duration == 0)
        #expect(copy.isVideo == false)
        #expect(copy.fileName.hasSuffix(".wav"))
        #expect(
            try Data(contentsOf: mediaDirectory.appendingPathComponent(copy.fileName)) == Data("rendered audio".utf8)
        )
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 1)
    }

    @Test func supportedExtensionsCanEditMetadataAndDraftFallsBackToModelValues() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let mediaDirectory = try sandbox.createDirectory(named: "Media")
        let fixture = try makePersistenceFixture(mediaDirectory: mediaDirectory)
        let item = makeItem(
            title: "Title",
            artist: "Unknown Artist",
            album: "Unknown Album",
            genre: nil,
            bookmarkData: Data([0xFF]),
            fileName: "missing.mp3"
        )

        #expect(fixture.service.canEditEmbeddedMetadata(for: item))
        item.fileName = "missing.xyz"
        #expect(fixture.service.canEditEmbeddedMetadata(for: item) == false)
        item.fileName = "missing.mp3"

        let draft = await fixture.service.editableMetadataDraft(for: item)

        #expect(draft.title == "Title")
        #expect(draft.artist.isEmpty)
        #expect(draft.album.isEmpty)
        #expect(draft.genre.isEmpty)
    }

    @Test func appOnlyLyricsSavePersistsWithoutChangingTheMediaFile() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }
        let mediaDirectory = try sandbox.createDirectory(named: "Media")
        let fixture = try makePersistenceFixture(mediaDirectory: mediaDirectory)
        let fileURL = mediaDirectory.appendingPathComponent("song.flac")
        let originalFileData = Data("unchanged audio".utf8)
        try originalFileData.write(to: fileURL)
        let item = makeItem(bookmarkData: Data([0xFF]), fileName: fileURL.lastPathComponent)
        fixture.context.insert(item)
        try fixture.context.save()

        try await fixture.service.saveLyrics(
            "First line\nSecond line",
            for: item,
            embedInFile: false,
            in: fixture.context
        )

        #expect(item.lyricsRaw == "First line\nSecond line")
        #expect(try Data(contentsOf: fileURL) == originalFileData)

        let verificationContext = ModelContext(fixture.container)
        let savedItem = try #require(verificationContext.fetch(FetchDescriptor<MediaItem>()).first)
        #expect(savedItem.lyricsRaw == "First line\nSecond line")

        try await fixture.service.saveLyrics(" \n ", for: item, embedInFile: false, in: fixture.context)
        #expect(item.lyricsRaw == nil)
    }
}

@MainActor
private func makePersistenceFixture(mediaDirectory: URL) throws -> (
    service: LibraryService,
    container: ModelContainer,
    context: ModelContext
) {
    let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return (LibraryService(mediaDirectoryURL: mediaDirectory), container, container.mainContext)
}

@MainActor
private func makeItem(
    title: String = "Title",
    artist: String = "Artist",
    album: String = "Album",
    genre: String? = nil,
    bookmarkData: Data,
    fileName: String
) -> MediaItem {
    MediaItem(
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        duration: 10,
        isVideo: false,
        bookmarkData: bookmarkData,
        fileName: fileName
    )
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleMediaPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createDirectory(named name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

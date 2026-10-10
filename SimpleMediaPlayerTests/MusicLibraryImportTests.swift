import AVFoundation
import ImageIO
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MusicLibraryImportTests {
    @Test func importsExportedCopyWithMusicMetadataAndPersistentID() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        var track = fixture.makeTrack(id: 7, fileName: "song.m4a", formatID: kAudioFormatMPEG4AAC)
        track.title = "Music Title"
        track.artist = "Music Artist"
        track.album = "Music Album"
        track.genre = "Jazz"
        track.year = "1999"
        track.trackNumber = "3/12"
        track.lyrics = "La la"
        let artwork = try makeArtworkImage()
        track.loadArtwork = { artwork }

        let result = try #require(await fixture.service.importMusicLibraryTracks(
            [track], into: fixture.context, existingItems: []
        ))

        #expect(result.importedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(result.messages.isEmpty)
        #expect(result.wasCancelled == false)
        let items = try fixture.items()
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.title == "Music Title")
        #expect(item.artist == "Music Artist")
        #expect(item.album == "Music Album")
        #expect(item.genre == "Jazz")
        #expect(item.year == "1999")
        #expect(item.trackNumber == "3/12")
        #expect(item.lyricsRaw == "La la")
        #expect(item.musicLibraryItemID == "7")
        #expect(item.hasArtwork)
        #expect(item.hasEditedTextMetadata == false)
        #expect(item.fileName.hasSuffix(".m4a"))
        #expect(try fixture.managedFiles().count == 1)
        #expect(try AVAudioFile(forReading: #require(fixture.service.resolvedURL(for: item))).length > 0)
        #expect(await fixture.temporaryFilesAreGone())
        #expect(fixture.service.musicLibraryPreparation == nil)
    }

    @Test func rejectedSongsAreReportedWithoutTouchingTheLibrary() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        var protected = fixture.makeTrack(id: 9, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        protected.hasProtectedAsset = true
        var cloud = fixture.makeTrack(id: 10, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        cloud.isCloudItem = true
        let missing = MusicLibraryTrack(id: 11)
        let unreadable = MusicLibraryTrack(id: 12, assetURL: fixture.directory.appendingPathComponent("none.m4a"))

        let result = try #require(await fixture.service.importMusicLibraryTracks(
            [protected, cloud, missing, unreadable], into: fixture.context, existingItems: []
        ))

        #expect(result.importedCount == 0)
        #expect(result.messages.count == 4)
        #expect(result.messages[0].contains(MusicLibraryTrackError.protectedAsset.localizedDescription))
        #expect(result.messages[1].contains(MusicLibraryTrackError.cloudItem.localizedDescription))
        #expect(result.messages[2].contains(MusicLibraryTrackError.noAssetURL.localizedDescription))
        #expect(try fixture.items().isEmpty)
        #expect(try fixture.managedFiles().isEmpty)
        #expect(await fixture.temporaryFilesAreGone())
    }

    @Test func cancellingTheImportRegistersNothing() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let tracks = (20..<24).map { fixture.makeTrack(id: $0, fileName: "song.wav", formatID: kAudioFormatLinearPCM) }
        let importTask = Task {
            await fixture.service.importMusicLibraryTracks(tracks, into: fixture.context, existingItems: [])
        }
        await fixture.waitForPreparation()
        fixture.service.cancelMusicLibraryPreparation()

        let result = try #require(await importTask.value)

        #expect(result.wasCancelled)
        #expect(result.importedCount == 0)
        #expect(try fixture.items().isEmpty)
        #expect(try fixture.managedFiles().isEmpty)
        #expect(await fixture.temporaryFilesAreGone())
    }

    @Test func preparesPlaybackWithoutRegisteringAnItem() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        var track = fixture.makeTrack(id: 30, fileName: "song.m4a", formatID: kAudioFormatMPEG4AAC)
        track.title = "Temporary"
        track.duration = 1

        let outcome = await fixture.service.prepareMusicLibraryPlayback(of: track)

        guard case let .ready(session) = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }
        let item = try #require(session.items.first)
        #expect(session.items.count == 1)
        #expect(item.modelContext == nil)
        #expect(item.isInLibrary == false)
        #expect(item.title == "Temporary")
        #expect(item.musicLibraryItemID == "30")
        let resolved = try #require(fixture.service.resolvedURL(for: item))
        #expect(resolved.standardizedFileURL.path.hasPrefix(session.directory.standardizedFileURL.path))
        #expect(try AVAudioFile(forReading: resolved).length == 44_100)
        #expect(try fixture.items().isEmpty)
        #expect(try fixture.managedFiles().isEmpty)
        #expect(fixture.service.musicLibraryPreparation == nil)

        session.end()
        await session.awaitCleanup()
        #expect(FileManager.default.fileExists(atPath: session.directory.path) == false)
    }

    @Test func replacedPlaybackPreparationIsCancelledAndCleanedUp() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let first = fixture.makeTrack(id: 31, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let second = fixture.makeTrack(id: 32, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let firstTask = Task { await fixture.service.prepareMusicLibraryPlayback(of: first) }
        await fixture.waitForPreparation()

        let secondOutcome = await fixture.service.prepareMusicLibraryPlayback(of: second)
        let firstOutcome = await firstTask.value

        guard case .cancelled = firstOutcome else {
            Issue.record("Expected the replaced preparation to be cancelled, got \(firstOutcome)")
            return
        }
        guard case let .ready(session) = secondOutcome else {
            Issue.record("Expected the newer preparation to finish, got \(secondOutcome)")
            return
        }
        #expect(session.items.first?.musicLibraryItemID == "32")
        session.end()
        await session.awaitCleanup()
        #expect(await fixture.temporaryFilesAreGone())
    }

    @Test func cancelledPlaybackPreparationLeavesNoFiles() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 33, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let task = Task { await fixture.service.prepareMusicLibraryPlayback(of: track) }
        await fixture.waitForPreparation()

        fixture.service.cancelMusicLibraryPreparation()
        let outcome = await task.value

        guard case .cancelled = outcome else {
            Issue.record("Expected cancellation, got \(outcome)")
            return
        }
        #expect(fixture.service.musicLibraryPreparation == nil)
        #expect(await fixture.temporaryFilesAreGone())
    }

    @Test func startupCleanupLeavesDirectoriesCreatedAfterwardsAlone() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let leftover = try MusicLibraryTemporaryFiles.makeDirectory(for: .playback, in: fixture.temporaryDirectory)
        try Data("stale".utf8).write(to: leftover.appendingPathComponent("stale.wav"))

        let cleanup = MusicLibraryTemporaryFiles.removeLeftoversInBackground(in: fixture.temporaryDirectory)
        let fresh = try MusicLibraryTemporaryFiles.makeDirectory(for: .importStaging, in: fixture.temporaryDirectory)
        try Data("live".utf8).write(to: fresh.appendingPathComponent("live.wav"))
        await cleanup.value

        #expect(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("live.wav").path))
        #expect(FileManager.default.fileExists(atPath: leftover.path) == false)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryDirectory.path)
        #expect(siblings == ["MusicLibrary"])
    }

    @Test func importOverrideOutranksEmbeddedValuesAndMarksUnembeddedTextAsEdited() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let embeddedSource = try writeAudio(named: "tagged.m4a", in: fixture.directory, formatID: kAudioFormatMPEG4AAC)
        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(title: "File Title", artist: "File Artist", album: "File Album", genre: "Rock"),
            to: embeddedSource
        )
        let plainSource = try writeAudio(named: "plain.wav", in: fixture.directory, formatID: kAudioFormatLinearPCM)
        var embeddedOverride = MediaImportOverride(musicLibraryItemID: "100", isEmbeddedInFile: true)
        embeddedOverride.values.title = "Music Title"
        embeddedOverride.values.artist = "Music Artist"
        var plainOverride = MediaImportOverride(musicLibraryItemID: "101", isEmbeddedInFile: false)
        plainOverride.values.title = "Override Title"
        plainOverride.lyrics = "Override lyrics"

        let summary = await fixture.service.importFiles(
            from: [embeddedSource, plainSource],
            overrides: [embeddedSource: embeddedOverride, plainSource: plainOverride],
            into: fixture.context, existingItems: []
        )

        let items = try fixture.items().sorted { $0.musicLibraryItemID ?? "" < $1.musicLibraryItemID ?? "" }
        #expect(items.count == 2)
        let embedded = try #require(items.first)
        #expect(embedded.title == "Music Title")
        #expect(embedded.artist == "Music Artist")
        #expect(embedded.album == "File Album")
        #expect(embedded.genre == "Rock")
        #expect(embedded.hasEditedTextMetadata == false)
        let plain = try #require(items.last)
        #expect(plain.title == "Override Title")
        #expect(plain.lyricsRaw == "Override lyrics")
        #expect(plain.hasEditedTextMetadata)
        #expect(plain.hasEditedLyrics)
        #expect(plain.editedTitle == "Override Title")
        #expect(summary == MediaImportSummary(createdCount: 2, duplicateCount: 0, errors: []))
    }

    /// Two queued requests for one song may both pass the pre-check; the serialized import still sees the ID.
    @Test func serializedImportRejectsASecondCopyOfTheSameMusicSong() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let first = try writeAudio(named: "first.wav", in: fixture.directory, formatID: kAudioFormatLinearPCM)
        let second = try writeAudio(named: "second.m4a", in: fixture.directory, formatID: kAudioFormatMPEG4AAC)
        let override = MediaImportOverride(musicLibraryItemID: "77")

        let firstSummary = await fixture.service.importFiles(
            from: [first], overrides: [first: override], into: fixture.context, existingItems: []
        )
        let secondSummary = await fixture.service.importFiles(
            from: [second], overrides: [second: override], into: fixture.context, existingItems: []
        )

        #expect(firstSummary == MediaImportSummary(createdCount: 1))
        #expect(secondSummary == MediaImportSummary(duplicateCount: 1))
        #expect(try fixture.items().count == 1)
        #expect(try fixture.managedFiles().count == 1)
    }

    /// Music's text set is authoritative even when it could not be written into the file.
    @Test func completeTextOverrideClearsEmbeddedValues() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let source = try writeAudio(named: "tagged.m4a", in: fixture.directory, formatID: kAudioFormatMPEG4AAC)
        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(title: "File Title", artist: "File Artist", album: "File Album", genre: "Rock"),
            to: source
        )
        var override = MediaImportOverride(musicLibraryItemID: "102", replacesTextFields: true)
        override.values.title = "Music Only Title"

        await fixture.service.importFiles(
            from: [source], overrides: [source: override], into: fixture.context, existingItems: []
        )

        let item = try #require(try fixture.items().first)
        #expect(item.title == "Music Only Title")
        #expect(item.artist == "Unknown Artist")
        #expect(item.album == "Unknown Album")
        #expect(item.genre == nil)
        #expect(item.hasEditedTextMetadata)
        #expect(item.editedArtist == "")
    }
}

private func makeArtworkImage() throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    return try #require(context.makeImage())
}

@MainActor
final class MusicLibraryFixture {
    let directory: URL
    let mediaDirectory: URL
    let temporaryDirectory: URL
    let container: ModelContainer
    let context: ModelContext
    let service: LibraryService

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryImportTests-\(UUID().uuidString)", isDirectory: true)
        mediaDirectory = directory.appendingPathComponent("Media", isDirectory: true)
        temporaryDirectory = directory.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = container.mainContext
        // The macOS Music lookup is not part of this feature; keep it out of the import messages.
        service = LibraryService(
            mediaDirectoryURL: mediaDirectory, temporaryDirectoryURL: temporaryDirectory,
            musicMetadataProvider: MusicLibraryMetadataProvider(loadSnapshot: {
                .loaded(MusicLibraryMetadataSnapshot(tracks: []))
            })
        )
    }

    /// A local file plays the role of the Music asset; the exporter only sees its URL.
    func makeTrack(id: UInt64, fileName: String, formatID: AudioFormatID) -> MusicLibraryTrack {
        let sourceDirectory = directory.appendingPathComponent("source-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let url = (try? writeAudio(named: fileName, in: sourceDirectory, formatID: formatID))
            ?? sourceDirectory.appendingPathComponent(fileName)
        var track = MusicLibraryTrack(id: id, assetURL: url)
        track.title = "Track \(id)"
        return track
    }

    func items() throws -> [MediaItem] {
        try context.fetch(FetchDescriptor<MediaItem>())
    }

    func managedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: mediaDirectory.path)
    }

    func waitForPreparation() async {
        for _ in 0..<200 where service.musicLibraryPreparation == nil {
            await Task.yield()
        }
    }

    /// Cleanup runs in a detached task, so the check waits briefly for it.
    func temporaryFilesAreGone() async -> Bool {
        let root = MusicLibraryTemporaryFiles.rootDirectory(in: temporaryDirectory)
        for _ in 0..<100 {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            let files = (enumerator?.allObjects as? [URL] ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            if files.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

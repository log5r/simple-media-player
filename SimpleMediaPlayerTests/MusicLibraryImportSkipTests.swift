import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

/// Skipping by Music persistent ID, playback artwork and startup cleanup, kept apart to bound the main suite.
@MainActor
struct MusicLibraryImportSkipTests {
    @Test func skipsSongsAlreadyImportedFromMusic() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 8, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        _ = await fixture.service.importMusicLibraryTracks([track], into: fixture.context, existingItems: [])

        let result = try #require(await fixture.service.importMusicLibraryTracks(
            [track], into: fixture.context, existingItems: try fixture.items()
        ))

        #expect(result.importedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.messages == [L10n.format("“%@” is already in your library.", track.displayTitle)])
        #expect(try fixture.items().count == 1)
        #expect(try fixture.managedFiles().count == 1)
        #expect(await fixture.temporaryFilesAreGone())
    }

    /// The pre-check list from before a deletion must not skip the song whose library copy is gone.
    @Test func staleExistingItemsDoNotSkipADeletedSong() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 13, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        _ = await fixture.service.importMusicLibraryTracks([track], into: fixture.context, existingItems: [])
        let staleItems = try fixture.items()
        await fixture.service.delete(try #require(staleItems.first), from: fixture.context)?.value

        let result = try #require(await fixture.service.importMusicLibraryTracks(
            [track], into: fixture.context, existingItems: staleItems
        ))

        #expect(result.importedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(try fixture.items().count == 1)
    }

    /// Cancelling while the pre-check probes earlier imports stops it and imports nothing. The cancel may
    /// land in the pre-check or in staging; both must leave the library and temporary files unchanged.
    @Test func cancellingDuringThePreCheckImportsNothing() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let seeded = (40..<44).map { fixture.makeTrack(id: $0, fileName: "song.wav", formatID: kAudioFormatLinearPCM) }
        _ = await fixture.service.importMusicLibraryTracks(seeded, into: fixture.context, existingItems: [])
        let existingItems = try fixture.items()
        let tracks = seeded + [fixture.makeTrack(id: 44, fileName: "song.wav", formatID: kAudioFormatLinearPCM)]
        let importTask = Task {
            await fixture.service.importMusicLibraryTracks(tracks, into: fixture.context, existingItems: existingItems)
        }
        await fixture.waitForPreparation()
        fixture.service.cancelMusicLibraryPreparation()

        let result = try #require(await importTask.value)

        #expect(result.wasCancelled)
        #expect(result.importedCount == 0)
        #expect(try fixture.items().count == seeded.count)
        #expect(try fixture.managedFiles().count == seeded.count)
        #expect(await fixture.temporaryFilesAreGone())
        #expect(fixture.service.musicLibraryPreparation == nil)
    }

    /// The pre-check only looks at the selected IDs; an unrelated Music import with a missing file is ignored.
    @Test func otherMusicImportsDoNotAffectTheSelection() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let other = fixture.makeTrack(id: 50, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        _ = await fixture.service.importMusicLibraryTracks([other], into: fixture.context, existingItems: [])
        for name in try fixture.managedFiles() {
            try FileManager.default.removeItem(at: fixture.mediaDirectory.appendingPathComponent(name))
        }
        let track = fixture.makeTrack(id: 51, fileName: "song.wav", formatID: kAudioFormatLinearPCM)

        let result = try #require(await fixture.service.importMusicLibraryTracks(
            [track], into: fixture.context, existingItems: try fixture.items()
        ))

        #expect(result.importedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(result.messages.isEmpty)
        #expect(try fixture.items().count == 2)
    }

    /// Trash left by an interrupted earlier launch is found by the background scan and removed.
    @Test func startupCleanupRemovesEarlierTrash() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let earlierTrash = fixture.temporaryDirectory
            .appendingPathComponent("MusicLibrary-Trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: earlierTrash, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: earlierTrash.appendingPathComponent("stale.wav"))

        await MusicLibraryTemporaryFiles.removeLeftoversInBackground(in: fixture.temporaryDirectory).value

        #expect(FileManager.default.fileExists(atPath: earlierTrash.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryDirectory.path).isEmpty)
    }

    /// A crashed playback session's analysis entry is keyed by a file under the old root; cleanup removes it.
    @Test func startupCleanupRemovesAnalysisEntriesOfCrashedPlayback() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let cacheDirectory = fixture.directory.appendingPathComponent("AnalysisCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let session = try MusicLibraryTemporaryFiles.makeDirectory(for: .playback, in: fixture.temporaryDirectory)
        let file = session.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: file)
        let entry = try #require(MusicAnalysisCache.entryURL(for: file, in: cacheDirectory))
        try Data("{}".utf8).write(to: entry)
        let unrelated = cacheDirectory.appendingPathComponent("unrelated.json")
        try Data("{}".utf8).write(to: unrelated)

        await MusicLibraryTemporaryFiles.removeLeftoversInBackground(
            in: fixture.temporaryDirectory, analysisCacheDirectory: cacheDirectory
        ).value

        #expect(FileManager.default.fileExists(atPath: entry.path) == false)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: session.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryDirectory.path).isEmpty)
    }

    /// A failed final save must not report the inserted items or leave their copied files behind.
    @Test func failedSaveDiscardsTheImportedItems() async throws {
        let fixture = try MusicLibraryFixture(saveContext: { _ in throw SaveFailure() })
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 60, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let saveMessage = L10n.format("Could not save: %@", SaveFailure().localizedDescription)

        let summary = await fixture.service.importFiles(
            from: [try #require(track.assetURL)], into: fixture.context, existingItems: []
        )

        #expect(summary.createdCount == 0)
        #expect(summary.errors.contains(saveMessage))
        #expect(try fixture.items().isEmpty)
        var files = try fixture.managedFiles()
        for _ in 0..<100 where files.isEmpty == false {
            try await Task.sleep(for: .milliseconds(20))
            files = try fixture.managedFiles()
        }
        #expect(files.isEmpty)
        let result = MusicLibraryImportResult(importedCount: summary.createdCount, messages: summary.errors)
        #expect(result.summary == [L10n.string("No songs were imported."), saveMessage].joined(separator: "\n"))
    }

    /// Playback never imports, so the deferred Music artwork must be resolved for the transient item.
    @Test func playbackItemCarriesTheMusicArtwork() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        var track = fixture.makeTrack(id: 31, fileName: "song.m4a", formatID: kAudioFormatMPEG4AAC)
        let artwork = try makeArtworkImage()
        track.loadArtwork = { artwork }

        let outcome = await fixture.service.prepareMusicLibraryPlayback(of: track)

        guard case let .ready(session) = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }
        let item = try #require(session.items.first)
        #expect(item.hasArtwork)
        #expect(item.artworkData != nil)
        #expect(try fixture.items().isEmpty)
        session.end()
        await session.awaitCleanup()
    }
}

private struct SaveFailure: LocalizedError {
    var errorDescription: String? { "Simulated save failure" }
}

import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

/// Skipping by Music persistent ID, kept apart from the main suite to bound its length.
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
}

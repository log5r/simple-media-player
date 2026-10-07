import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MediaImportMigrationTests {
    @Test func opensExistingLibraryAndPreservesPlaylistRelationships() async throws {
        try await withTemporaryArtworkStorage { directory in
            let storeURL = directory.url.appendingPathComponent("library.store")
            let itemID = UUID()
            let playlistID = UUID()
            let entryID = UUID()

            try createLegacyStore(at: storeURL, itemID: itemID, playlistID: playlistID, entryID: entryID)

            let container = try autoreleasepool {
                let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
                let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: [configuration])
            }
            try await LibraryArtworkStorage.migrate(in: container)

            try autoreleasepool {
                let context = container.mainContext
                let items = try context.fetch(FetchDescriptor<MediaItem>())
                let item = try #require(items.first)
                #expect(items.count == 1)
                expectLegacyMetadata(item, id: itemID)
                #expect(item.hasEditedLyrics == false)
                #expect(item.hasEditedTextMetadata == false)
                #expect(item.editedTitle == nil)
                #expect(item.editedArtist == nil)
                #expect(item.editedAlbum == nil)
                #expect(try context.fetchCount(FetchDescriptor<MediaArtwork>()) == 1)

                let playlists = try context.fetch(FetchDescriptor<Playlist>())
                let playlist = try #require(playlists.first)
                #expect(playlists.count == 1)
                #expect(playlist.id == playlistID)
                #expect(playlist.name == "Legacy playlist")
                #expect(playlist.createdAt == Date(timeIntervalSince1970: 1_700_000_001))
                let entry = try #require(playlist.entries.first)
                #expect(playlist.entries.count == 1)
                #expect(entry.id == entryID)
                #expect(entry.sortIndex == 7)
                #expect(entry.item?.id == itemID)
                #expect(entry.playlist?.id == playlistID)
                #expect(try context.fetchCount(FetchDescriptor<PlaylistEntry>()) == 1)

                item.importFingerprint = "sha256:migrated"
                try context.save()
                let verificationContext = ModelContext(container)
                let savedItem = try #require(verificationContext.fetch(FetchDescriptor<MediaItem>()).first)
                #expect(savedItem.importFingerprint == "sha256:migrated")
            }
        }
    }

    private func createLegacyStore(at storeURL: URL, itemID: UUID, playlistID: UUID, entryID: UUID) throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: PreFingerprintLibrarySchema.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let item = PreFingerprintLibrarySchema.MediaItem(id: itemID)
            let playlist = PreFingerprintLibrarySchema.Playlist(id: playlistID)
            let entry = PreFingerprintLibrarySchema.PlaylistEntry(
                id: entryID,
                sortIndex: 7,
                playlist: playlist,
                item: item
            )
            context.insert(item)
            context.insert(playlist)
            context.insert(entry)
            try context.save()
        }
    }

    private func expectLegacyMetadata(_ item: MediaItem, id: UUID) {
        #expect(item.id == id)
        #expect(item.title == "Legacy title")
        #expect(item.artist == "Legacy artist")
        #expect(item.album == "Legacy album")
        #expect(item.genre == "Legacy genre")
        #expect(item.year == "2020")
        #expect(item.trackNumber == "3")
        #expect(item.comment == "Legacy comment")
        #expect(item.albumArtist == "Legacy album artist")
        #expect(item.composer == "Legacy composer")
        #expect(item.discNumber == "2")
        #expect(item.isCompilation)
        #expect(item.duration == 123)
        #expect(item.isVideo == false)
        #expect(item.lyricsRaw == "Legacy lyrics")
        #expect(item.bookmarkData == Data([1, 2, 3]))
        #expect(item.artworkData == Data([4, 5, 6]))
        #expect(item.hasArtwork)
        #expect(item.artworkID == item.artwork?.id)
        #expect(item.legacyArtworkData == nil)
        #expect(item.addedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(item.fileName == "legacy.mp3")
        #expect(item.importFingerprint == nil)
    }
}

// Preserve the stored model shape from before the optional fingerprint was added.
private enum PreFingerprintLibrarySchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [MediaItem.self, Playlist.self, PlaylistEntry.self] }

    @Model
    final class MediaItem {
        var id: UUID
        var title: String
        var artist: String
        var album: String
        var genre: String?
        var year: String? = nil
        var trackNumber: String? = nil
        var comment: String? = nil
        var albumArtist: String? = nil
        var composer: String? = nil
        var discNumber: String? = nil
        var isCompilation: Bool = false
        var duration: TimeInterval
        var isVideo: Bool
        var lyricsRaw: String?
        var bookmarkData: Data
        var artworkData: Data?
        var addedAt: Date
        var fileName: String

        init(id: UUID) {
            self.id = id
            title = "Legacy title"
            artist = "Legacy artist"
            album = "Legacy album"
            genre = "Legacy genre"
            year = "2020"
            trackNumber = "3"
            comment = "Legacy comment"
            albumArtist = "Legacy album artist"
            composer = "Legacy composer"
            discNumber = "2"
            isCompilation = true
            duration = 123
            isVideo = false
            lyricsRaw = "Legacy lyrics"
            bookmarkData = Data([1, 2, 3])
            artworkData = Data([4, 5, 6])
            addedAt = Date(timeIntervalSince1970: 1_700_000_000)
            fileName = "legacy.mp3"
        }
    }

    @Model
    final class Playlist {
        var id: UUID
        var name: String
        var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.playlist)
        var entries: [PlaylistEntry]

        init(id: UUID) {
            self.id = id
            name = "Legacy playlist"
            createdAt = Date(timeIntervalSince1970: 1_700_000_001)
            entries = []
        }
    }

    @Model
    final class PlaylistEntry {
        var id: UUID
        var sortIndex: Int
        var playlist: Playlist?
        var item: MediaItem?

        init(id: UUID, sortIndex: Int, playlist: Playlist?, item: MediaItem?) {
            self.id = id
            self.sortIndex = sortIndex
            self.playlist = playlist
            self.item = item
        }
    }
}

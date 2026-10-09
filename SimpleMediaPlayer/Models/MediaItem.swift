import Foundation
import SwiftData

@Model
nonisolated final class MediaItem {
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
    // Empty edited values remain authoritative when embedded metadata is read again.
    var hasEditedLyrics: Bool = false
    var hasEditedTextMetadata: Bool = false
    // Preserve tag values independently of title/artist/album display fallbacks.
    var editedTitle: String?
    var editedArtist: String?
    var editedAlbum: String?
    var bookmarkData: Data
    var artworkID: UUID?
    @Relationship(deleteRule: .cascade)
    var artwork: MediaArtwork?
    // Retain the old column until its bytes have been moved to a separate entity.
    @Attribute(originalName: "artworkData")
    var legacyArtworkData: Data?
    var addedAt: Date
    var fileName: String
    // Keep the original import identity even when embedded metadata is edited later.
    var importFingerprint: String? = nil
    // Music library persistent ID of the song an import was exported from; exports never share bytes.
    var musicLibraryItemID: String?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "Unknown Artist",
        album: String = "Unknown Album",
        genre: String? = nil,
        year: String? = nil,
        trackNumber: String? = nil,
        comment: String? = nil,
        albumArtist: String? = nil,
        composer: String? = nil,
        discNumber: String? = nil,
        isCompilation: Bool = false,
        duration: TimeInterval,
        isVideo: Bool,
        lyricsRaw: String? = nil,
        bookmarkData: Data,
        artworkData: Data? = nil,
        addedAt: Date = Date(),
        fileName: String,
        importFingerprint: String? = nil,
        musicLibraryItemID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.comment = comment
        self.albumArtist = albumArtist
        self.composer = composer
        self.discNumber = discNumber
        self.isCompilation = isCompilation
        self.duration = duration
        self.isVideo = isVideo
        self.lyricsRaw = lyricsRaw
        self.bookmarkData = bookmarkData
        let artwork = artworkData.map { MediaArtwork(data: $0) }
        self.artwork = artwork
        self.artworkID = artwork?.id
        self.legacyArtworkData = nil
        self.addedAt = addedAt
        self.fileName = fileName
        self.importFingerprint = importFingerprint
        self.musicLibraryItemID = musicLibraryItemID
    }

    var hasArtwork: Bool { artworkID != nil }

    // Read only for compatibility with existing callers; list and playback UI use artworkID.
    var artworkData: Data? {
        get { artwork?.data ?? legacyArtworkData }
        set {
            let previousArtwork = artwork
            let replacement = newValue.map { MediaArtwork(data: $0) }
            if let replacement, let modelContext {
                modelContext.insert(replacement)
            }
            artwork = replacement
            artworkID = replacement?.id
            legacyArtworkData = nil
            if let previousArtwork, let modelContext {
                modelContext.delete(previousArtwork)
            }
        }
    }
}

@Model
nonisolated final class MediaArtwork {
    var id: UUID
    @Attribute(.externalStorage)
    var data: Data

    init(id: UUID = UUID(), data: Data) {
        self.id = id
        self.data = data
    }
}

@Model
nonisolated final class Playlist {
    var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.playlist)
    var entries: [PlaylistEntry]

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), entries: [PlaylistEntry] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.entries = entries
    }
}

@Model
nonisolated final class PlaylistEntry {
    var id: UUID
    var sortIndex: Int
    var playlist: Playlist?
    var item: MediaItem?

    init(id: UUID = UUID(), sortIndex: Int, playlist: Playlist? = nil, item: MediaItem? = nil) {
        self.id = id
        self.sortIndex = sortIndex
        self.playlist = playlist
        self.item = item
    }
}

extension MediaItem {
    /// False for items that only exist for playback, such as Music library songs played without saving.
    /// Library edits, copies, and playlist membership are limited to inserted items.
    var isInLibrary: Bool {
        modelContext != nil && isDeleted == false
    }

    var displayContentType: String {
        // `URL(fileURLWithPath:)` stats the path to detect directories; the list needs only the name.
        let pathExtension = (fileName as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pathExtension.isEmpty ? "-" : pathExtension.uppercased()
    }

    var displayArtist: String {
        localizedMetadata(artist, fallbackKey: "Unknown Artist")
    }

    var displayAlbum: String {
        localizedMetadata(album, fallbackKey: "Unknown Album")
    }

    var displayGenre: String {
        localizedMetadata(genre ?? "", fallbackKey: "No Genre")
    }

    private func localizedMetadata(_ value: String, fallbackKey: String.LocalizationValue) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return L10n.string(fallbackKey)
        }

        switch trimmed {
        case "Unknown Artist":
            return L10n.string("Unknown Artist")
        case "Unknown Album":
            return L10n.string("Unknown Album")
        default:
            return trimmed
        }
    }
}

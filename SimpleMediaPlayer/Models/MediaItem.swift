import Foundation
import SwiftData

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
    // Keep the original import identity even when embedded metadata is edited later.
    var importFingerprint: String? = nil

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
        importFingerprint: String? = nil
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
        self.artworkData = artworkData
        self.addedAt = addedAt
        self.fileName = fileName
        self.importFingerprint = importFingerprint
    }
}

@Model
final class Playlist {
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
final class PlaylistEntry {
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
    var displayContentType: String {
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension
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

import Foundation
import SwiftData

/// Values belonging to the source when an export starts, independent of later edits or deletion.
struct TransformedTrackSourceSnapshot: Sendable {
    let registeredID: UUID?
    let metadata: MediaMetadataModelValues
    let editedArtist: String?
    let editedAlbum: String?
    let hasEditedTextMetadata: Bool
    let lyricsRaw: String?
    var artworkData: Data?

    @MainActor init(item: MediaItem) {
        registeredID = item.modelContext == nil ? nil : item.id
        metadata = MediaMetadataModelValues(
            title: item.title, artist: item.artist, album: item.album, genre: item.genre,
            year: item.year, trackNumber: item.trackNumber, comment: item.comment,
            albumArtist: item.albumArtist, composer: item.composer, discNumber: item.discNumber,
            isCompilation: item.isCompilation
        )
        lyricsRaw = item.lyricsRaw
        editedArtist = item.editedArtist
        editedAlbum = item.editedAlbum
        hasEditedTextMetadata = item.hasEditedTextMetadata
        // Filled from the asynchronous artwork read after the model values have been frozen.
        artworkData = nil
    }

    @MainActor func applyEditedMetadata(to item: MediaItem, title: String) throws {
        try Task.checkCancellation()
        item.editedTitle = hasEditedTextMetadata ? title : nil
        item.editedArtist = editedArtist
        item.editedAlbum = editedAlbum
        item.hasEditedTextMetadata = hasEditedTextMetadata
    }
}

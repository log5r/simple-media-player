import Foundation

extension LibraryService {
    /// `storedArtwork` is the item's artwork read before the file's tags; it wins when it overrides them.
    func draftPreservingStoredEdits(
        _ original: MediaMetadataEditDraft, for item: MediaItem, storedArtwork: Data? = nil
    ) -> MediaMetadataEditDraft {
        var draft = original
        if item.hasEditedTextMetadata {
            // Text writers replace the complete editable field set, including empty values.
            draft = MediaMetadataEditDraft(item: item)
            draft.artworkData = original.artworkData
            draft.lyrics = original.lyrics
            draft.editsTextMetadata = original.editsTextMetadata
            draft.editsArtwork = original.editsArtwork
            draft.editsLyrics = original.editsLyrics
            draft.textFields = original.textFields
        }
        if item.hasEditedLyrics {
            draft.lyrics = item.lyricsRaw ?? ""
        }
        if item.hasEditedArtwork {
            draft.artworkData = storedArtwork
        }
        return draft
    }
}

extension MediaItem {
    /// Sets the fields in `draft.textFields`, which the file received, and keeps the item's values for the others.
    func applyTextValues(of draft: MediaMetadataEditDraft, fileURL url: URL) {
        let values = draft.normalizedModelValues(fileURL: url)
        func set<Value>(_ field: MediaMetadataEditField, _ keyPath: ReferenceWritableKeyPath<MediaItem, Value>,
                        _ value: Value) {
            if draft.textFields.contains(field) { self[keyPath: keyPath] = value }
        }
        set(.title, \.title, values.title)
        set(.artist, \.artist, values.artist)
        set(.album, \.album, values.album)
        set(.genre, \.genre, values.genre)
        set(.year, \.year, values.year)
        set(.trackNumber, \.trackNumber, values.trackNumber)
        set(.comment, \.comment, values.comment)
        set(.albumArtist, \.albumArtist, values.albumArtist)
        set(.composer, \.composer, values.composer)
        set(.discNumber, \.discNumber, values.discNumber)
        set(.isCompilation, \.isCompilation, values.isCompilation)
    }

    func setEditedTextMetadata(_ draft: MediaMetadataEditDraft) {
        editedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        editedArtist = draft.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        editedAlbum = draft.album.trimmingCharacters(in: .whitespacesAndNewlines)
        hasEditedTextMetadata = true
    }

    func setEditedLyrics(_ lyrics: String?) {
        lyricsRaw = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : lyrics
        hasEditedLyrics = true
    }
}

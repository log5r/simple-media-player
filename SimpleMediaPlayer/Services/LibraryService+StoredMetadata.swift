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

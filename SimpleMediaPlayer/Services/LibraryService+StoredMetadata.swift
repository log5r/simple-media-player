import Foundation

extension LibraryService {
    func draftPreservingStoredEdits(_ original: MediaMetadataEditDraft, for item: MediaItem) -> MediaMetadataEditDraft {
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
        return draft
    }
}

extension MediaItem {
    func setEditedLyrics(_ lyrics: String?) {
        lyricsRaw = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : lyrics
        hasEditedLyrics = true
    }
}

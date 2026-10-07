import Foundation

extension MediaMetadataEditDraft {
    nonisolated func forSaving(comparedTo original: MediaMetadataEditDraft) -> MediaMetadataEditDraft {
        var draft = self
        draft.editsTextMetadata = textMetadataValues != original.textMetadataValues
        return draft
    }

    nonisolated private var textMetadataValues: MediaMetadataEmbeddedValues {
        MediaMetadataEmbeddedValues(
            title: title, artist: artist, album: album, genre: genre, year: year,
            trackNumber: trackNumber, comment: comment, albumArtist: albumArtist,
            composer: composer, discNumber: discNumber, isCompilation: isCompilation
        )
    }
}

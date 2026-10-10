import Foundation
import SwiftData

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

    /// The item's values as the base of a bulk patch, read from the file only for an ambiguous placeholder.
    /// `MediaMetadataEditDraft(item:)` reads an unedited item's `Unknown Artist` and `Unknown Album` as empty,
    /// since they are usually display fallbacks, but the file may hold that literal text; recording the empty
    /// value as an edit would then hide and later delete it. So for an unpatched placeholder, the file's tag
    /// decides, and an unreadable file keeps the empty value. No other file value enters the draft, so the
    /// recorded edits stay the values the item shows.
    func bulkPatchBaseDraft(
        for item: MediaItem, patching fields: Set<MediaMetadataEditField>
    ) async throws -> MediaMetadataEditDraft {
        let placeholders = unpatchedPlaceholderFields(of: item, patching: fields)
        guard placeholders.isEmpty == false else { return MediaMetadataEditDraft(item: item) }
        let itemID = item.id
        let bookmarkData = item.bookmarkData
        let fileName = item.fileName
        let embedded: MediaMetadataEditDraft?
        do {
            embedded = try await editableMetadataDraft(for: item, includesArtwork: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            embedded = nil
        }
        // The read belongs to the item's file as it was; an item replaced or deleted meanwhile is not patched.
        guard item.id == itemID, item.bookmarkData == bookmarkData, item.fileName == fileName,
              item.isDeleted == false else { throw CancellationError() }
        var draft = MediaMetadataEditDraft(item: item)
        let current = placeholders.intersection(unpatchedPlaceholderFields(of: item, patching: fields))
        let whitespace = CharacterSet.whitespacesAndNewlines
        if current.contains(.artist), embedded?.artist.trimmingCharacters(in: whitespace) == "Unknown Artist" {
            draft.artist = "Unknown Artist"
        }
        if current.contains(.album), embedded?.album.trimmingCharacters(in: whitespace) == "Unknown Album" {
            draft.album = "Unknown Album"
        }
        return draft
    }

    /// The unpatched artist and album of an unedited item that show the placeholder for a missing value, which
    /// `MediaMetadataEditDraft(item:)` maps to an empty value.
    private func unpatchedPlaceholderFields(
        of item: MediaItem, patching fields: Set<MediaMetadataEditField>
    ) -> Set<MediaMetadataEditField> {
        guard item.hasEditedTextMetadata == false else { return [] }
        var result: Set<MediaMetadataEditField> = []
        if fields.contains(.artist) == false, item.editedArtist == nil, item.artist == "Unknown Artist" {
            result.insert(.artist)
        }
        if fields.contains(.album) == false, item.editedAlbum == nil, item.album == "Unknown Album" {
            result.insert(.album)
        }
        return result
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

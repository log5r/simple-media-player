import AVFoundation
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

    /// The item's values as the base of a write that replaces `fields`, such as a bulk patch or a transformed
    /// copy's new title, read from the file only for an ambiguous placeholder.
    /// `MediaMetadataEditDraft(item:)` reads an unedited item's `Unknown Artist` and `Unknown Album` as empty,
    /// since they are usually display fallbacks, but the file may hold that literal text; writing or recording
    /// the empty value would then hide and later delete it. So for an unpatched placeholder, the file's tag
    /// decides, and an unreadable file keeps the empty value. No other file value enters the draft, so the
    /// written and recorded values stay the values the item shows.
    func itemDraftResolvingPlaceholders(
        for item: MediaItem, patching fields: Set<MediaMetadataEditField>
    ) async throws -> MediaMetadataEditDraft {
        try Task.checkCancellation()
        let placeholders = unpatchedPlaceholderFields(of: item, patching: fields)
        guard placeholders.isEmpty == false else { return MediaMetadataEditDraft(item: item) }
        let itemID = item.id
        let bookmarkData = item.bookmarkData
        let fileName = item.fileName
        let reference = fileReference(for: item)
        let embedded: MediaMetadataEmbeddedValues?
        do {
            let readTask = Task.detached(
                executorPreference: BlockingWorkExecutor.shared, priority: .utility
            ) { [self] in
                try Task.checkCancellation()
                let url = resolvedURL(for: reference)
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let values = try await PlaceholderTagReader.read(from: url, fields: placeholders)
                try Task.checkCancellation()
                return values
            }
            embedded = try await withTaskCancellationHandler {
                try await readTask.value
            } onCancel: { readTask.cancel() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            embedded = nil
        }
        try Task.checkCancellation()
        // The read belongs to the item's file as it was; an item replaced or deleted meanwhile is not patched.
        guard item.id == itemID, item.bookmarkData == bookmarkData, item.fileName == fileName,
              item.isDeleted == false, deletedItemIDs.contains(itemID) == false else { throw CancellationError() }
        var draft = MediaMetadataEditDraft(item: item)
        let current = placeholders.intersection(unpatchedPlaceholderFields(of: item, patching: fields))
        let whitespace = CharacterSet.whitespacesAndNewlines
        if current.contains(.artist), embedded?.artist?.trimmingCharacters(in: whitespace) == "Unknown Artist" {
            draft.artist = "Unknown Artist"
        }
        if current.contains(.album), embedded?.album?.trimmingCharacters(in: whitespace) == "Unknown Album" {
            draft.album = "Unknown Album"
        }
        return draft
    }

    /// The unpatched artist and album of an unedited item that show the placeholder for a missing value, which
    /// `MediaMetadataEditDraft(item:)` maps to an empty value. None when the patch has no text field, since such a
    /// patch records no text edits.
    func unpatchedPlaceholderFields(
        of item: MediaItem, patching fields: Set<MediaMetadataEditField>
    ) -> Set<MediaMetadataEditField> {
        guard item.hasEditedTextMetadata == false,
              fields.isDisjoint(with: MediaMetadataEditDraft.allTextFields) == false else { return [] }
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

/// Reads only the ambiguous text. Missing native tags stay missing rather than triggering an AVAsset probe.
private nonisolated enum PlaceholderTagReader {
    static func read(from url: URL, fields: Set<MediaMetadataEditField>) async throws -> MediaMetadataEmbeddedValues {
        if ID3TagWriter.canWriteMetadata(to: url) {
            let native: MediaMetadataEmbeddedValues
            do {
                native = try ID3TagWriter.readMetadata(from: url, textFields: fields) ?? MediaMetadataEmbeddedValues()
            } catch {
                try Task.checkCancellation()
                return try await commonValues(from: url, fields: fields)
            }
            // AVFoundation can expose an ID3v1 artist/album when ID3v2 is absent. Probe only its 3-byte marker;
            // ordinary missing tags never take this fallback. Keep the editor's ID3v2 precedence.
            guard needsID3v1Fallback(native, fields: fields), try hasID3v1Tag(at: url) else { return native }
            var values = try await commonValues(from: url, fields: fields)
            values.artist = native.artist ?? values.artist
            values.album = native.album ?? values.album
            return values
        }
        if MP4MetadataWriter.canWriteMetadata(to: url) {
            let native: MediaMetadataEmbeddedValues?
            do {
                native = try MP4MetadataReader.read(from: url, textFields: fields)?.values
                guard try MP4MetadataReader.requiresCommonTextFallback(from: url) else {
                    return native ?? MediaMetadataEmbeddedValues()
                }
            } catch {
                try Task.checkCancellation()
                return try await commonValues(from: url, fields: fields)
            }
            var values = try await commonValues(from: url, fields: fields)
            values.artist = native?.artist ?? values.artist
            values.album = native?.album ?? values.album
            return values
        }
        if url.pathExtension.lowercased() == "flac" || AdditionalAudioMetadata.canWrite(to: url) {
            do {
                return try AdditionalAudioMetadata.read(from: url, textFields: fields).values
            } catch {
                try Task.checkCancellation()
                return try await commonValues(from: url, fields: fields)
            }
        }
        if let kind = try ExtendedAudioSource.kind(for: url) {
            let info = try ExtendedAudioSource.info(for: url, kind: kind)
            return MediaMetadataEmbeddedValues(artist: info.artist, album: info.album)
        }
        // AIFF and other AVFoundation formats retain their common artist/album interpretation.
        return try await commonValues(from: url, fields: fields)
    }

    private static func needsID3v1Fallback(
        _ values: MediaMetadataEmbeddedValues, fields: Set<MediaMetadataEditField>
    ) -> Bool {
        (fields.contains(.artist) && values.artist == nil) || (fields.contains(.album) && values.album == nil)
    }

    private static func hasID3v1Tag(at url: URL) throws -> Bool {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let size = try source.seekToEnd()
        guard size >= 128 else { return false }
        return try MediaFileRewriter.read(from: source, at: size - 128, count: 3) == Data("TAG".utf8)
    }

    private static func commonValues(
        from url: URL, fields: Set<MediaMetadataEditField>
    ) async throws -> MediaMetadataEmbeddedValues {
        try Task.checkCancellation()
        let metadata = try await AVURLAsset(url: url).load(.commonMetadata)
        var values = MediaMetadataEmbeddedValues()
        if fields.contains(.artist) {
            values.artist = await firstString(in: metadata, identifier: .commonIdentifierArtist)
        }
        if fields.contains(.album) {
            values.album = await firstString(in: metadata, identifier: .commonIdentifierAlbumName)
        }
        try Task.checkCancellation()
        return values
    }

    private static func firstString(in metadata: [AVMetadataItem], identifier: AVMetadataIdentifier) async -> String? {
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
            if let value = try? await item.load(.stringValue), value.isEmpty == false { return value }
        }
        return nil
    }
}

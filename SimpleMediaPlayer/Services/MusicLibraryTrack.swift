import Foundation

/// A value snapshot of one Music library item. MediaPlayer objects stay on the main actor; preparation
/// and import work only with this copy, so a late result cannot read a changed or released item.
nonisolated struct MusicLibraryTrack: Identifiable, Sendable, Equatable {
    let id: UInt64
    var assetURL: URL?
    var hasProtectedAsset = false
    var isCloudItem = false
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var year: String?
    var trackNumber: String?
    var discNumber: String?
    var comment: String?
    var isCompilation = false
    var lyrics: String?
    var duration: TimeInterval = 0
    var artworkData: Data?

    init(id: UInt64, assetURL: URL? = nil) {
        self.id = id
        self.assetURL = assetURL
    }

    /// Stored in `MediaItem.musicLibraryItemID` so a second import of the same song is recognized even
    /// though every export produces different bytes.
    var libraryItemID: String { String(id) }

    var displayTitle: String {
        Self.nonblank(title) ?? L10n.format("Music Track %@", libraryItemID)
    }

    /// Only names the exported copy, which the library renames anyway; the item title comes from
    /// `metadataValues`. Unique within one staging directory even when titles repeat.
    var exportBaseName: String {
        libraryItemID
    }

    /// Music library values replace embedded tags on import. Fields that are empty in Music stay empty
    /// instead of falling back to the file's tags; only the title always has a value.
    var metadataValues: MediaMetadataEmbeddedValues {
        MediaMetadataEmbeddedValues(
            title: displayTitle, artist: Self.nonblank(artist), album: Self.nonblank(album),
            genre: Self.nonblank(genre), year: Self.nonblank(year), trackNumber: Self.nonblank(trackNumber),
            comment: Self.nonblank(comment), albumArtist: Self.nonblank(albumArtist),
            composer: Self.nonblank(composer), discNumber: Self.nonblank(discNumber),
            isCompilation: isCompilation
        )
    }

    var normalizedLyrics: String? {
        Self.nonblank(lyrics)
    }

    /// Checks the picker-level flags before any asset is opened. Readability and exportability of the
    /// asset itself are verified by the exporter.
    func validatedAssetURL() throws(MusicLibraryTrackError) -> URL {
        if hasProtectedAsset { throw .protectedAsset }
        if isCloudItem { throw .cloudItem }
        guard let assetURL else { throw .noAssetURL }
        return assetURL
    }

    static func numberPair(current: Int, total: Int) -> String? {
        guard current > 0 else { return nil }
        return total > 0 ? "\(current)/\(total)" : "\(current)"
    }

    static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum MusicLibraryTrackError: LocalizedError, Equatable {
    case protectedAsset
    case cloudItem
    case noAssetURL
    case notReadable
    case notExportable
    case noAudioTrack
    case outputNotDecodable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .protectedAsset:
            L10n.string("This song is protected and cannot be used.")
        case .cloudItem:
            L10n.string("This song is not downloaded to this device.")
        case .noAssetURL:
            L10n.string("This song has no file on this device.")
        case .notReadable:
            L10n.string("This song cannot be read.")
        case .notExportable:
            L10n.string("This song cannot be exported.")
        case .noAudioTrack:
            L10n.string("This song has no audio track.")
        case .outputNotDecodable:
            L10n.string("The exported file could not be decoded.")
        case let .exportFailed(message):
            L10n.format("Export failed: %@", message)
        }
    }
}

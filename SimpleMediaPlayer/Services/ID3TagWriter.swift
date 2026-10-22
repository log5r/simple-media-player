import Foundation

struct MediaMetadataEditDraft: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var year: String
    var trackNumber: String
    var comment: String
    var albumArtist: String
    var composer: String
    var discNumber: String
    var isCompilation: Bool
    var artworkData: Data?
    var lyrics: String
    var editsTextMetadata: Bool
    var editsArtwork: Bool
    var editsLyrics: Bool
    /// The text fields that a write with `editsTextMetadata` replaces; the file keeps the values of the others.
    var textFields: Set<MediaMetadataEditField> = Self.allTextFields

    /// Every field except artwork, which `editsArtwork` covers.
    nonisolated static let allTextFields: Set<MediaMetadataEditField> = [
        .title, .artist, .album, .genre, .year, .trackNumber, .comment, .albumArtist, .composer, .discNumber,
        .isCompilation
    ]

    nonisolated init(
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: String = "",
        trackNumber: String = "",
        comment: String = "",
        albumArtist: String = "",
        composer: String = "",
        discNumber: String = "",
        isCompilation: Bool = false,
        artworkData: Data? = nil,
        lyrics: String = "",
        editsTextMetadata: Bool = true,
        editsArtwork: Bool = false,
        editsLyrics: Bool = false
    ) {
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
        self.artworkData = artworkData
        self.lyrics = lyrics
        self.editsTextMetadata = editsTextMetadata
        self.editsArtwork = editsArtwork
        self.editsLyrics = editsLyrics
    }

    @MainActor
    init(item: MediaItem) {
        title = item.editedTitle ?? item.title
        artist = item.editedArtist ?? (item.artist == "Unknown Artist" ? "" : item.artist)
        album = item.editedAlbum ?? (item.album == "Unknown Album" ? "" : item.album)
        genre = item.genre ?? ""
        year = item.year ?? ""
        trackNumber = item.trackNumber ?? ""
        comment = item.comment ?? ""
        albumArtist = item.albumArtist ?? ""
        composer = item.composer ?? ""
        discNumber = item.discNumber ?? ""
        isCompilation = item.isCompilation
        // Artwork is loaded explicitly by the asynchronous editor/export paths.
        artworkData = nil
        lyrics = item.lyricsRaw ?? ""
        editsTextMetadata = true
        editsArtwork = false
        editsLyrics = false
    }

    nonisolated func normalizedModelValues(fileURL: URL) -> MediaMetadataModelValues {
        let title = normalized(title) ?? fileURL.deletingPathExtension().lastPathComponent
        let artist = normalized(artist) ?? "Unknown Artist"
        let album = normalized(album) ?? "Unknown Album"
        let genre = normalized(genre)
        return MediaMetadataModelValues(
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            year: normalized(year),
            trackNumber: normalized(trackNumber),
            comment: normalized(comment),
            albumArtist: normalized(albumArtist),
            composer: normalized(composer),
            discNumber: normalized(discNumber),
            isCompilation: isCompilation
        )
    }

    nonisolated var writableFrameValues: [String: String] {
        var values: [String: String] = [:]
        values["TIT2"] = normalized(title)
        values["TPE1"] = normalized(artist)
        values["TALB"] = normalized(album)
        values["TCON"] = normalized(genre)
        values["TDRC"] = normalized(year)
        values["TYER"] = normalized(year)
        values["TRCK"] = normalized(trackNumber)
        values["TPE2"] = normalized(albumArtist)
        values["TCOM"] = normalized(composer)
        values["TPOS"] = normalized(discNumber)
        values["TCMP"] = isCompilation ? "1" : nil
        return values
    }

    nonisolated var writableCommentValue: String? {
        normalized(comment)
    }

    nonisolated func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private func nonblank(_ value: String?) -> String? {
        guard let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return value
    }

    nonisolated func applying(_ values: MediaMetadataEmbeddedValues) -> MediaMetadataEditDraft {
        var draft = MediaMetadataEditDraft(
            title: nonblank(values.title) ?? title,
            artist: nonblank(values.artist) ?? artist,
            album: nonblank(values.album) ?? album,
            genre: nonblank(values.genre) ?? genre,
            year: nonblank(values.year) ?? year,
            trackNumber: nonblank(values.trackNumber) ?? trackNumber,
            comment: nonblank(values.comment) ?? comment,
            albumArtist: nonblank(values.albumArtist) ?? albumArtist,
            composer: nonblank(values.composer) ?? composer,
            discNumber: nonblank(values.discNumber) ?? discNumber,
            isCompilation: values.isCompilation ?? isCompilation,
            artworkData: artworkData,
            lyrics: lyrics,
            editsTextMetadata: editsTextMetadata,
            editsArtwork: editsArtwork,
            editsLyrics: editsLyrics
        )
        draft.textFields = textFields
        return draft
    }

    /// Whether a write replaces `field` in the file.
    nonisolated func writesText(_ field: MediaMetadataEditField) -> Bool {
        editsTextMetadata && textFields.contains(field)
    }
}

enum MediaMetadataEditField: String, CaseIterable, Sendable {
    case artwork
    case title
    case artist
    case album
    case genre
    case year
    case trackNumber
    case comment
    case albumArtist
    case composer
    case discNumber
    case isCompilation
}

struct MediaMetadataEditPatch: Equatable, Sendable {
    var fields: Set<MediaMetadataEditField>
    var draft: MediaMetadataEditDraft

    nonisolated init(fields: Set<MediaMetadataEditField> = [], draft: MediaMetadataEditDraft) {
        self.fields = fields
        self.draft = draft
    }

    nonisolated var isEmpty: Bool {
        fields.isEmpty
    }

    nonisolated func applying(to original: MediaMetadataEditDraft) -> MediaMetadataEditDraft {
        var patched = original
        // Writers replace only the patched text fields, so the file keeps its values for the others.
        patched.textFields = fields.isEmpty ? original.textFields : fields.subtracting([.artwork])
        patched.editsTextMetadata = fields.isEmpty ? original.editsTextMetadata : patched.textFields.isEmpty == false
        for field in fields {
            switch field {
            case .artwork:
                patched.artworkData = draft.artworkData
                patched.editsArtwork = true
            case .title:
                patched.title = draft.title
            case .artist:
                patched.artist = draft.artist
            case .album:
                patched.album = draft.album
            case .genre:
                patched.genre = draft.genre
            case .year:
                patched.year = draft.year
            case .trackNumber:
                patched.trackNumber = draft.trackNumber
            case .comment:
                patched.comment = draft.comment
            case .albumArtist:
                patched.albumArtist = draft.albumArtist
            case .composer:
                patched.composer = draft.composer
            case .discNumber:
                patched.discNumber = draft.discNumber
            case .isCompilation:
                patched.isCompilation = draft.isCompilation
            }
        }
        return patched
    }
}

struct MediaMetadataModelValues: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var genre: String?
    var year: String?
    var trackNumber: String?
    var comment: String?
    var albumArtist: String?
    var composer: String?
    var discNumber: String?
    var isCompilation: Bool
}

nonisolated struct MediaMetadataEmbeddedValues: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var trackNumber: String?
    var comment: String?
    var albumArtist: String?
    var composer: String?
    var discNumber: String?
    var isCompilation: Bool?
}

enum MediaMetadataEditError: LocalizedError, Equatable {
    case cannotResolveFile
    case unsupportedFileFormat
    case unsupportedID3Version(UInt8)
    case unsupportedID3Flags
    case invalidID3Tag
    case invalidMP4Metadata
    case unsupportedMP4MetadataLayout
    case invalidAIFFMetadata
    case unsupportedAIFFMetadataLayout
    case invalidArtwork
    case invalidAudioMetadata

    nonisolated var errorDescription: String? {
        switch self {
        case .cannotResolveFile:
            L10n.string("Could not resolve the media file.")
        case .unsupportedFileFormat:
            L10n.string("This file format does not support editing embedded metadata.")
        case let .unsupportedID3Version(version):
            L10n.format("This ID3 tag version is not supported: ID3v2.%d", Int(version))
        case .unsupportedID3Flags:
            L10n.string("This ID3 tag uses features that are not supported for editing.")
        case .invalidID3Tag:
            L10n.string("The embedded ID3 tag is invalid.")
        case .invalidMP4Metadata:
            L10n.string("The embedded MP4 metadata is invalid.")
        case .unsupportedMP4MetadataLayout:
            L10n.string("This MP4 metadata layout is not supported for editing.")
        case .invalidAIFFMetadata:
            L10n.string("The embedded AIFF metadata is invalid.")
        case .unsupportedAIFFMetadataLayout:
            L10n.string("This AIFF metadata layout is not supported for editing.")
        case .invalidArtwork:
            L10n.string("The selected file is not a valid image.")
        case .invalidAudioMetadata:
            L10n.string("The embedded audio metadata is invalid or uses an unsupported layout.")
        }
    }
}
extension ID3TagWriter {
    /// A tag whose header keeps the existing tag's size, so it replaces only that tag; nil without a tag, when it
    /// grows, or when the range to write exceeds `MediaFileRewriter.inPlaceTagLimit`.
    nonisolated static func paddedTagEdit(
        for draft: MediaMetadataEditDraft,
        existingTagData data: Data
    ) throws -> MediaFileRewriter.InPlaceEdit? {
        guard let header = try tagHeader(in: data) else { return nil }
        var tagData = try updatedTagData(for: draft, existingTagData: data)
        // The new tag has no footer, so zero padding may fill the old tag's space, footer included. Only the old
        // bytes up to the last nonzero one need clearing; the zeros after it already are padding, which can be
        // nearly 256 MiB.
        let oldContentEnd = data.withUnsafeBytes { $0[10..<header.totalEnd].lastIndex { $0 != 0 } }.map { $0 + 1 }
        let end = max(tagData.count, oldContentEnd ?? 0)
        guard tagData.count <= header.totalEnd, header.totalEnd - 10 <= 0x0FFF_FFFF,
              UInt64(end) <= MediaFileRewriter.inPlaceTagLimit else { return nil }
        tagData.append(Data(count: end - tagData.count))
        tagData.replaceSubrange(6..<10, with: synchsafeData(header.totalEnd - 10))
        return MediaFileRewriter.InPlaceEdit(offset: 0, originalLength: UInt64(end), data: tagData)
    }

    /// `tagData` for the full rewrite. When it does not take exactly the `oldSize` bytes of the old tag, which moves
    /// the audio anyway, `MediaFileRewriter.rewritePadding` zero bytes follow the frames, so a later save that grows
    /// the tag a little takes `paddedTagEdit`. ID3v2.2 to 2.4 allow padding; the tag has no footer, which 2.4
    /// forbids together with padding.
    nonisolated static func rewrittenTag(_ tagData: Data, replacing oldSize: Int) -> Data {
        let size = tagData.count - 10 + MediaFileRewriter.rewritePadding
        guard tagData.count != oldSize, size <= 0x0FFF_FFFF else { return tagData }
        var padded = tagData + Data(count: MediaFileRewriter.rewritePadding)
        padded.replaceSubrange(6..<10, with: synchsafeData(size))
        return padded
    }
}

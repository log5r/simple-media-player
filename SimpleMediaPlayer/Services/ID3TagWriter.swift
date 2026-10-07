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
        title = item.title
        artist = item.artist == "Unknown Artist" ? "" : item.artist
        album = item.album == "Unknown Album" ? "" : item.album
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

    nonisolated fileprivate var writableFrameValues: [String: String] {
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

    nonisolated fileprivate var writableCommentValue: String? {
        normalized(comment)
    }

    nonisolated fileprivate func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private func nonblank(_ value: String?) -> String? {
        guard let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return value
    }

    nonisolated func applying(_ values: MediaMetadataEmbeddedValues) -> MediaMetadataEditDraft {
        MediaMetadataEditDraft(
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

enum ID3TagWriter {
    nonisolated private static let editableFrameIDs: Set<String> = [
        "TIT2", "TPE1", "TALB", "TCON", "TDRC", "TYER", "TRCK", "COMM", "TPE2", "TCOM", "TPOS", "TCMP",
        "TT2", "TP1", "TAL", "TCO", "TYE", "TRK", "COM", "TP2", "TCM", "TPA", "TCP"
    ]
    nonisolated private static let lyricsFrameIDs: Set<String> = ["USLT", "ULT", "SYLT", "SLT"]

    nonisolated static func canWriteMetadata(to url: URL) -> Bool {
        url.pathExtension.localizedCaseInsensitiveCompare("mp3") == .orderedSame
    }

    nonisolated static func readMetadata(from url: URL) throws -> MediaMetadataEmbeddedValues? {
        guard canWriteMetadata(to: url) else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }

        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let fileSize = try source.seekToEnd()
        let data = try readTagData(from: source, at: 0, count: fileSize)
        guard let tag = try existingTag(in: data) else { return nil }
        return embeddedValues(in: tag)
    }

    nonisolated static func readEmbeddedTag(_ data: Data) throws -> AudioTagReadResult? {
        guard let tag = try existingTag(in: data) else { return nil }
        var result = AudioTagReadResult()
        var otherArtwork: Data?
        result.values = embeddedValues(in: tag)
        for frame in tag.frames {
            let payload = frame.payload
            if (frame.id == "APIC" || frame.id == "PIC"), result.artworkData == nil, payload.count >= 5 {
                let encoding = payload[payload.startIndex]
                var cursor = payload.index(after: payload.startIndex)
                if frame.id == "PIC" {
                    cursor = payload.index(cursor, offsetBy: 3, limitedBy: payload.endIndex) ?? payload.endIndex
                } else if let terminator = payload[cursor...].firstIndex(of: 0) {
                    cursor = payload.index(after: terminator)
                } else { continue }
                guard cursor < payload.endIndex else { continue }
                let pictureType = payload[cursor]
                cursor = payload.index(after: cursor) // picture type
                guard cursor < payload.endIndex,
                      let terminator = encodedStringTerminator(in: payload[cursor...], encodingByte: encoding)
                else { continue }
                let end = payload.index(terminator, offsetBy: encoding == 1 || encoding == 2 ? 2 : 1)
                if end < payload.endIndex {
                    let artwork = Data(payload[end...])
                    if pictureType == 3 { result.artworkData = artwork }
                    else if otherArtwork == nil { otherArtwork = artwork }
                }
            } else if (frame.id == "USLT" || frame.id == "ULT"), result.lyrics == nil, payload.count >= 5 {
                let encoding = payload[payload.startIndex]
                let body = payload.dropFirst(4)
                if let terminator = encodedStringTerminator(in: body, encodingByte: encoding) {
                    let start = body.index(terminator, offsetBy: encoding == 1 || encoding == 2 ? 2 : 1)
                    result.lyrics = decodeText(body[start...], encodingByte: encoding)
                }
            }
        }
        result.artworkData = result.artworkData ?? otherArtwork
        return result
    }

    nonisolated static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        guard canWriteMetadata(to: url) else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }

        try MediaFileRewriter.rewrite(at: url) { source, output, fileSize in
            let data = try readTagData(from: source, at: 0, count: fileSize)
            let tagData = try updatedTagData(for: draft, existingTagData: data)
            let audioStart = UInt64(try tagHeader(in: data)?.totalEnd ?? 0)
            try output.write(contentsOf: tagData)
            try MediaFileRewriter.copy(from: source, range: audioStart..<fileSize, to: output)
        }
    }

    nonisolated static func readTagData(from source: FileHandle, at offset: UInt64, count: UInt64) throws -> Data {
        let prefix = try MediaFileRewriter.read(from: source, at: offset, count: Int(min(10, count)))
        guard let header = try tagHeader(in: prefix) else { return prefix }
        guard UInt64(header.totalEnd) <= count else {
            throw MediaMetadataEditError.invalidID3Tag
        }
        return try MediaFileRewriter.read(from: source, at: offset, count: header.totalEnd)
    }

    nonisolated static func updatedTagData(
        for draft: MediaMetadataEditDraft,
        existingTagData: Data?,
        requiresExistingTag: Bool = false
    ) throws -> Data {
        let existingTag: ID3Tag?
        if let existingTagData, existingTagData.isEmpty == false {
            existingTag = try Self.existingTag(in: existingTagData)
            if existingTag == nil, requiresExistingTag {
                throw MediaMetadataEditError.invalidID3Tag
            }
        } else {
            existingTag = nil
        }

        let version = existingTag?.version ?? 3
        guard version == 2 || version == 3 || version == 4 else {
            throw MediaMetadataEditError.unsupportedID3Version(version)
        }

        var removedFrameIDs: Set<String> = []
        if draft.editsTextMetadata {
            removedFrameIDs.formUnion(editableFrameIDs)
        }
        if draft.editsLyrics {
            removedFrameIDs.formUnion(lyricsFrameIDs)
        }
        var frames = existingTag?.preservedFrames(
            removing: removedFrameIDs, removeFrontArtwork: draft.editsArtwork
        ) ?? []
        if draft.editsTextMetadata {
            for frame in textFrames(for: version) {
                if let value = draft.writableFrameValues[frame.canonicalID] {
                    frames.append(makeTextFrame(id: frame.id, value: value, version: version))
                }
            }
            if let comment = draft.writableCommentValue {
                frames.append(makeCommentFrame(value: comment, version: version))
            }
        }
        if draft.editsArtwork, let artworkData = draft.artworkData {
            frames.append(makeArtworkFrame(data: artworkData, version: version))
        }
        if draft.editsLyrics, let lyrics = draft.normalized(draft.lyrics) {
            frames.append(makeLyricsFrame(value: lyrics, version: version))
        }

        return makeTag(frames: frames, version: version)
    }

    nonisolated private static func existingTag(in data: Data) throws -> ID3Tag? {
        guard let header = try tagHeader(in: data) else { return nil }
        let version = header.version
        let contentStart = 10
        let contentEnd = header.contentEnd
        guard header.totalEnd <= data.count else {
            throw MediaMetadataEditError.invalidID3Tag
        }

        var frameStart = contentStart
        if version != 2 && (header.flags & 0x40) != 0 {
            frameStart = try skipExtendedHeader(
                version: version,
                data: data,
                contentStart: contentStart,
                contentEnd: contentEnd
            )
        }

        let frames = try parseFrames(in: data, range: frameStart..<contentEnd, version: version)
        return ID3Tag(version: version, totalRange: 0..<header.totalEnd, frames: frames)
    }

    nonisolated private static func tagHeader(
        in data: Data
    ) throws -> (version: UInt8, flags: UInt8, contentEnd: Int, totalEnd: Int)? {
        guard data.count >= 10 else { return nil }
        guard data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil }

        let version = data[3]
        guard version == 2 || version == 3 || version == 4 else {
            throw MediaMetadataEditError.unsupportedID3Version(version)
        }

        let flags = data[5]
        let hasFooter = version == 4 && (flags & 0x10) != 0
        let unsupportedFlags: UInt8 = version == 2 ? 0xC0 : 0x80
        guard (flags & unsupportedFlags) == 0 else {
            throw MediaMetadataEditError.unsupportedID3Flags
        }

        let tagSize = try synchsafeInteger(data[6..<10])
        let contentEnd = 10 + tagSize
        let totalEnd = contentEnd + (hasFooter ? 10 : 0)
        return (version, flags, contentEnd, totalEnd)
    }

    nonisolated private static func skipExtendedHeader(
        version: UInt8,
        data: Data,
        contentStart: Int,
        contentEnd: Int
    ) throws -> Int {
        guard contentStart + 4 <= contentEnd else {
            throw MediaMetadataEditError.invalidID3Tag
        }

        let size: Int
        if version == 4 {
            size = try synchsafeInteger(data[contentStart..<(contentStart + 4)])
        } else {
            size = bigEndianInteger(data[contentStart..<(contentStart + 4)])
                + 4
        }

        let frameStart = contentStart + size
        guard size >= 4, frameStart <= contentEnd else {
            throw MediaMetadataEditError.invalidID3Tag
        }
        return frameStart
    }

    nonisolated private static func parseFrames(in data: Data, range: Range<Int>, version: UInt8) throws -> [ID3Frame] {
        var offset = range.lowerBound
        var frames: [ID3Frame] = []
        let headerSize = version == 2 ? 6 : 10
        let idLength = version == 2 ? 3 : 4

        while offset + headerSize <= range.upperBound {
            let header = data[offset..<(offset + headerSize)]
            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            guard let frameID = String(data: data[offset..<(offset + idLength)], encoding: .isoLatin1),
                  frameID.count == idLength,
                  frameID.utf8.allSatisfy(isFrameIDByte)
            else {
                break
            }

            let sizeRange = version == 2
                ? (offset + 3)..<(offset + 6)
                : (offset + 4)..<(offset + 8)
            let frameSize: Int
            if version == 4 {
                frameSize = try synchsafeInteger(data[sizeRange])
            } else {
                frameSize = bigEndianInteger(data[sizeRange])
            }
            guard frameSize >= 0 else {
                throw MediaMetadataEditError.invalidID3Tag
            }

            let frameEnd = offset + headerSize + frameSize
            guard frameEnd <= range.upperBound else {
                throw MediaMetadataEditError.invalidID3Tag
            }

            frames.append(ID3Frame(id: frameID, rawData: Data(data[offset..<frameEnd])))
            offset = frameEnd
        }

        return frames
    }

    nonisolated private static func makeTag(frames: [Data], version: UInt8) -> Data {
        var content = Data()
        for frame in frames {
            content.append(frame)
        }

        var tag = Data()
        tag.append(contentsOf: [0x49, 0x44, 0x33, version, 0, 0])
        tag.append(synchsafeData(content.count))
        tag.append(content)
        return tag
    }

    nonisolated private static func isFrameIDByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
    }

    nonisolated private static func textFrames(for version: UInt8) -> [(id: String, canonicalID: String)] {
        if version == 2 {
            return [
                ("TT2", "TIT2"),
                ("TP1", "TPE1"),
                ("TAL", "TALB"),
                ("TCO", "TCON"),
                ("TYE", "TYER"),
                ("TRK", "TRCK"),
                ("TP2", "TPE2"),
                ("TCM", "TCOM"),
                ("TPA", "TPOS"),
                ("TCP", "TCMP")
            ]
        }

        let yearFrame = version == 4 ? ("TDRC", "TDRC") : ("TYER", "TYER")
        return [
            ("TIT2", "TIT2"),
            ("TPE1", "TPE1"),
            ("TALB", "TALB"),
            ("TCON", "TCON"),
            yearFrame,
            ("TRCK", "TRCK"),
            ("TPE2", "TPE2"),
            ("TCOM", "TCOM"),
            ("TPOS", "TPOS"),
            ("TCMP", "TCMP")
        ]
    }

    nonisolated private static func makeTextFrame(id: String, value: String, version: UInt8) -> Data {
        var payload = Data()
        if version == 4 {
            payload.append(0x03)
            payload.append(Data(value.utf8))
        } else {
            payload.append(0x01)
            payload.append(value.data(using: .utf16) ?? Data(value.utf8))
        }

        var frame = Data()
        frame.append(Data(id.utf8))
        if version == 2 {
            frame.append(bigEndianData(payload.count, byteCount: 3))
        } else {
            frame.append(version == 4 ? synchsafeData(payload.count) : bigEndianData(payload.count, byteCount: 4))
            frame.append(contentsOf: [0, 0])
        }
        frame.append(payload)
        return frame
    }

    nonisolated private static func makeCommentFrame(value: String, version: UInt8) -> Data {
        var payload = Data()
        if version == 4 {
            payload.append(0x03)
            payload.append(Data("eng".utf8))
            payload.append(0x00)
            payload.append(Data(value.utf8))
        } else {
            payload.append(0x01)
            payload.append(Data("eng".utf8))
            payload.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
            payload.append(value.data(using: .utf16) ?? Data(value.utf8))
        }

        let id = version == 2 ? "COM" : "COMM"
        var frame = Data()
        frame.append(Data(id.utf8))
        if version == 2 {
            frame.append(bigEndianData(payload.count, byteCount: 3))
        } else {
            frame.append(version == 4 ? synchsafeData(payload.count) : bigEndianData(payload.count, byteCount: 4))
            frame.append(contentsOf: [0, 0])
        }
        frame.append(payload)
        return frame
    }

    nonisolated private static func makeLyricsFrame(value: String, version: UInt8) -> Data {
        var payload = Data()
        if version == 4 {
            payload.append(0x03)
            payload.append(Data("eng".utf8))
            payload.append(0x00)
            payload.append(Data(value.utf8))
        } else {
            payload.append(0x01)
            payload.append(Data("eng".utf8))
            payload.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
            payload.append(value.data(using: .utf16) ?? Data(value.utf8))
        }

        let id = version == 2 ? "ULT" : "USLT"
        var frame = Data(id.utf8)
        if version == 2 {
            frame.append(bigEndianData(payload.count, byteCount: 3))
        } else {
            frame.append(version == 4 ? synchsafeData(payload.count) : bigEndianData(payload.count, byteCount: 4))
            frame.append(contentsOf: [0, 0])
        }
        frame.append(payload)
        return frame
    }

    nonisolated private static func makeArtworkFrame(data: Data, version: UInt8) -> Data {
        var payload = Data([0])
        if version == 2 {
            payload.append(Data(artworkFormat(for: data).utf8))
        } else {
            payload.append(Data(artworkMIMEType(for: data).utf8))
            payload.append(0)
        }
        payload.append(3) // Front cover
        payload.append(0) // Empty ISO-8859-1 description
        payload.append(data)

        let id = version == 2 ? "PIC" : "APIC"
        var frame = Data(id.utf8)
        if version == 2 {
            frame.append(bigEndianData(payload.count, byteCount: 3))
        } else {
            frame.append(version == 4 ? synchsafeData(payload.count) : bigEndianData(payload.count, byteCount: 4))
            frame.append(contentsOf: [0, 0])
        }
        frame.append(payload)
        return frame
    }

    nonisolated private static func artworkMIMEType(for data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    nonisolated private static func artworkFormat(for data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "PNG" : "JPG"
    }

    nonisolated private static func embeddedValues(in tag: ID3Tag) -> MediaMetadataEmbeddedValues {
        var values = MediaMetadataEmbeddedValues()

        for frame in tag.frames {
            switch frame.canonicalID {
            case "TIT2":
                values.title = textValue(in: frame)
            case "TPE1":
                values.artist = textValue(in: frame)
            case "TALB":
                values.album = textValue(in: frame)
            case "TCON":
                values.genre = textValue(in: frame)
            case "TDRC", "TYER":
                values.year = textValue(in: frame)
            case "TRCK":
                values.trackNumber = textValue(in: frame)
            case "TPE2":
                values.albumArtist = textValue(in: frame)
            case "TCOM":
                values.composer = textValue(in: frame)
            case "TPOS":
                values.discNumber = textValue(in: frame)
            case "TCMP":
                values.isCompilation = boolValue(in: frame)
            case "COMM":
                if let comment = commentValue(in: frame) {
                    values.comment = comment
                }
            default:
                continue
            }
        }

        return values
    }

    nonisolated private static func textValue(in frame: ID3Frame) -> String? {
        guard frame.payload.isEmpty == false else { return nil }
        return decodeText(frame.payload.dropFirst(), encodingByte: frame.payload[frame.payload.startIndex])
    }

    nonisolated private static func boolValue(in frame: ID3Frame) -> Bool? {
        guard let text = textValue(in: frame)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if ["1", "true", "yes"].contains(text) { return true }
        if ["0", "false", "no"].contains(text) { return false }
        return nil
    }

    nonisolated private static func commentValue(in frame: ID3Frame) -> String? {
        let payload = frame.payload
        guard payload.count >= 5 else { return nil }
        let encoding = payload[payload.startIndex]
        let body = payload.dropFirst(4)
        let separatorLength = encoding == 1 || encoding == 2 ? 2 : 1
        guard let textStart = encodedStringTerminator(in: body, encodingByte: encoding)
            .map({ $0 + separatorLength }) else {
            return nil
        }

        let description = decodeText(body[..<textStart].dropLast(separatorLength), encodingByte: encoding)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard description?.hasPrefix("iTun") != true else { return nil }

        return decodeText(body[textStart...], encodingByte: encoding)
    }

    nonisolated private static func encodedStringTerminator(
        in bytes: Data.SubSequence,
        encodingByte: UInt8
    ) -> Data.SubSequence.Index? {
        if encodingByte == 1 || encodingByte == 2 {
            guard bytes.count >= 2 else { return nil }
            var index = bytes.startIndex
            while index < bytes.endIndex {
                let next = bytes.index(after: index)
                guard next < bytes.endIndex else { return nil }
                if bytes[index] == 0, bytes[next] == 0 {
                    return index
                }
                index = bytes.index(index, offsetBy: 2, limitedBy: bytes.endIndex) ?? bytes.endIndex
            }
            return nil
        }

        return bytes.firstIndex(of: 0)
    }

    nonisolated private static func decodeText(_ bytes: Data.SubSequence, encodingByte: UInt8) -> String? {
        let data = Data(bytes)
        let string: String?
        switch encodingByte {
        case 0:
            string = String(data: data, encoding: .isoLatin1)
        case 1:
            string = String(data: data, encoding: .utf16)
        case 2:
            string = String(data: data, encoding: .utf16BigEndian)
        case 3:
            string = String(data: data, encoding: .utf8)
        default:
            string = String(data: data, encoding: .utf8)
        }

        let trimmed = string?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated private static func synchsafeInteger(_ bytes: Data.SubSequence) throws -> Int {
        guard bytes.count == 4 else {
            throw MediaMetadataEditError.invalidID3Tag
        }

        var value = 0
        for byte in bytes {
            guard byte & 0x80 == 0 else {
                throw MediaMetadataEditError.invalidID3Tag
            }
            value = (value << 7) | Int(byte)
        }
        return value
    }

    nonisolated private static func synchsafeData(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    nonisolated private static func bigEndianInteger(_ bytes: Data.SubSequence) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    nonisolated private static func bigEndianData(_ value: Int, byteCount: Int) -> Data {
        var data = Data()
        for index in stride(from: byteCount - 1, through: 0, by: -1) {
            data.append(UInt8((value >> (index * 8)) & 0xFF))
        }
        return data
    }
}

private struct ID3Tag {
    let version: UInt8
    let totalRange: Range<Int>
    let frames: [ID3Frame]

    nonisolated func preservedFrames(removing frameIDs: Set<String>, removeFrontArtwork: Bool) -> [Data] {
        frames
            .filter { frame in
                frameIDs.contains(frame.id) == false && (removeFrontArtwork == false || frame.pictureType != 3)
            }
            .map(\.rawData)
    }
}

private struct ID3Frame {
    let id: String
    let rawData: Data

    nonisolated var payload: Data.SubSequence {
        rawData.dropFirst(id.count == 3 ? 6 : 10)
    }

    nonisolated var pictureType: UInt8? {
        let data = payload
        guard data.count >= 5 else { return nil }
        if id == "PIC" { return data[data.startIndex + 4] }
        guard id == "APIC", let terminator = data[data.startIndex...].dropFirst().firstIndex(of: 0),
              terminator + 1 < data.endIndex else { return nil }
        return data[terminator + 1]
    }

    nonisolated var canonicalID: String {
        switch id {
        case "TT2":
            "TIT2"
        case "TP1":
            "TPE1"
        case "TAL":
            "TALB"
        case "TCO":
            "TCON"
        case "TYE":
            "TYER"
        case "TRK":
            "TRCK"
        case "COM":
            "COMM"
        case "TP2":
            "TPE2"
        case "TCM":
            "TCOM"
        case "TPA":
            "TPOS"
        case "TCP":
            "TCMP"
        default:
            id
        }
    }
}

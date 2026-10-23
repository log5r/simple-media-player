import Foundation

enum ID3TagWriter {
    /// The frames a text write replaces, by the field they hold, for ID3v2.3/2.4 and ID3v2.2 frame IDs.
    nonisolated static let editableFrameFields: [String: MediaMetadataEditField] = [
        "TIT2": .title, "TPE1": .artist, "TALB": .album, "TCON": .genre, "TDRC": .year, "TYER": .year,
        "TRCK": .trackNumber, "COMM": .comment, "TPE2": .albumArtist, "TCOM": .composer, "TPOS": .discNumber,
        "TCMP": .isCompilation,
        "TT2": .title, "TP1": .artist, "TAL": .album, "TCO": .genre, "TYE": .year, "TRK": .trackNumber,
        "COM": .comment, "TP2": .albumArtist, "TCM": .composer, "TPA": .discNumber, "TCP": .isCompilation
    ]
    nonisolated static let lyricsFrameIDs: Set<String> = ["USLT", "ULT", "SYLT", "SLT"]

    nonisolated static func canWriteMetadata(to url: URL) -> Bool {
        url.pathExtension.localizedCaseInsensitiveCompare("mp3") == .orderedSame
    }

    nonisolated static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        guard canWriteMetadata(to: url) else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }

        try MediaFileRewriter.update(at: url) { source, fileSize in
            try paddedTagEdit(for: draft, existingTagData: readTagData(from: source, at: 0, count: fileSize))
        } rewrite: { source, output, fileSize in
            let data = try readTagData(from: source, at: 0, count: fileSize)
            let audioStart = try tagHeader(in: data)?.totalEnd ?? 0
            let tagData = try rewrittenTag(updatedTagData(for: draft, existingTagData: data), replacing: audioStart)
            try output.write(contentsOf: tagData)
            try MediaFileRewriter.copy(from: source, range: UInt64(audioStart)..<fileSize, to: output)
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

        var removedFrameIDs = Set(editableFrameFields.compactMap { draft.writesText($0.value) ? $0.key : nil })
        if draft.editsLyrics {
            removedFrameIDs.formUnion(lyricsFrameIDs)
        }
        var frames = try existingTag?.preservedFrames(
            removing: removedFrameIDs, removeFrontArtwork: draft.editsArtwork
        ) ?? []
        for frame in textFrames(for: version) {
            if let field = editableFrameFields[frame.canonicalID], draft.writesText(field),
               let value = draft.writableFrameValues[frame.canonicalID] {
                frames.append(makeTextFrame(id: frame.id, value: value, version: version))
            }
        }
        if draft.writesText(.comment), let comment = draft.writableCommentValue {
            frames.append(makeCommentFrame(value: comment, version: version))
        }
        if draft.editsArtwork, let artworkData = draft.artworkData {
            frames.append(makeArtworkFrame(data: artworkData, version: version))
        }
        if draft.editsLyrics, let lyrics = draft.normalized(draft.lyrics) {
            frames.append(makeLyricsFrame(value: lyrics, version: version))
        }

        return makeTag(frames: frames, version: version)
    }

}

extension ID3TagWriter {
    nonisolated static func existingTag(in data: Data) throws -> ID3Tag? {
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

    nonisolated static func tagHeader(
        in data: Data
    ) throws -> ID3TagHeader? {
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
        return ID3TagHeader(version: version, flags: flags, contentEnd: contentEnd, totalEnd: totalEnd)
    }

    nonisolated static func skipExtendedHeader(
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

    nonisolated static func parseFrames(in data: Data, range: Range<Int>, version: UInt8) throws -> [ID3Frame] {
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

            frames.append(ID3Frame(id: frameID, rawData: Data(data[offset..<frameEnd]), version: version))
            offset = frameEnd
        }

        return frames
    }

}

extension ID3TagWriter {
    nonisolated static func makeTag(frames: [Data], version: UInt8) -> Data {
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

    nonisolated static func isFrameIDByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
    }

    nonisolated static func textFrames(for version: UInt8) -> [(id: String, canonicalID: String)] {
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

    nonisolated static func makeTextFrame(id: String, value: String, version: UInt8) -> Data {
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

    nonisolated static func makeCommentFrame(value: String, version: UInt8) -> Data {
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

    nonisolated static func makeLyricsFrame(value: String, version: UInt8) -> Data {
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

    nonisolated static func makeArtworkFrame(data: Data, version: UInt8) -> Data {
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

    nonisolated static func artworkMIMEType(for data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    nonisolated static func artworkFormat(for data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "PNG" : "JPG"
    }

    nonisolated static func synchsafeInteger(_ bytes: Data.SubSequence) throws -> Int {
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

    nonisolated static func synchsafeData(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    nonisolated static func bigEndianInteger(_ bytes: Data.SubSequence) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    nonisolated static func bigEndianData(_ value: Int, byteCount: Int) -> Data {
        var data = Data()
        for index in stride(from: byteCount - 1, through: 0, by: -1) {
            data.append(UInt8((value >> (index * 8)) & 0xFF))
        }
        return data
    }}

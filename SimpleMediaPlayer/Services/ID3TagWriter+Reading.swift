import Foundation

extension ID3TagWriter {

    nonisolated static func embeddedValues(
        in tag: ID3Tag, textFields: Set<MediaMetadataEditField>? = nil
    ) -> MediaMetadataEmbeddedValues {
        var values = MediaMetadataEmbeddedValues()

        for frame in tag.frames {
            if let textFields, editableFrameFields[frame.id].map(textFields.contains) != true { continue }
            applyTextFrame(frame, to: &values)
            applyOtherFrame(frame, to: &values)
        }

        return values
    }

    nonisolated static func applyTextFrame(_ frame: ID3Frame, to values: inout MediaMetadataEmbeddedValues) {
        switch frame.canonicalID {
        case "TIT2":
            values.title = textValue(in: frame)
        case "TPE1":
            values.artist = textValue(in: frame)
        case "TALB":
            values.album = textValue(in: frame)
        case "TCON":
            values.genre = textValue(in: frame)
        case "TRCK":
            values.trackNumber = textValue(in: frame)
        case "TPE2":
            values.albumArtist = textValue(in: frame)
        case "TCOM":
            values.composer = textValue(in: frame)
        case "TPOS":
            values.discNumber = textValue(in: frame)
        default: break
        }
    }

    nonisolated static func applyOtherFrame(_ frame: ID3Frame, to values: inout MediaMetadataEmbeddedValues) {
        switch frame.canonicalID {
        case "TDRC", "TYER":
            values.year = textValue(in: frame)
        case "TCMP":
            values.isCompilation = boolValue(in: frame)
        case "COMM":
            if let comment = commentValue(in: frame) {
                values.comment = comment
            }
        default: break
        }
    }

    nonisolated static func textValue(in frame: ID3Frame) -> String? {
        guard frame.payload.isEmpty == false else { return nil }
        return decodeText(frame.payload.dropFirst(), encodingByte: frame.payload[frame.payload.startIndex])
    }

    nonisolated static func boolValue(in frame: ID3Frame) -> Bool? {
        guard let text = textValue(in: frame)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if ["1", "true", "yes"].contains(text) { return true }
        if ["0", "false", "no"].contains(text) { return false }
        return nil
    }

    nonisolated static func commentValue(in frame: ID3Frame) -> String? {
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

    nonisolated static func encodedStringTerminator(
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

    nonisolated static func decodeText(_ bytes: Data.SubSequence, encodingByte: UInt8) -> String? {
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

    nonisolated static func readMetadata(
        from url: URL, textFields: Set<MediaMetadataEditField>? = nil
    ) throws -> MediaMetadataEmbeddedValues? {
        guard canWriteMetadata(to: url) else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let fileSize = try source.seekToEnd()
        let data = try readTagData(from: source, at: 0, count: fileSize)
        guard let tag = try existingTag(in: data) else { return nil }
        return embeddedValues(in: tag, textFields: textFields)
    }
    nonisolated static func readEmbeddedTag(
        _ data: Data, textFields: Set<MediaMetadataEditField>? = nil
    ) throws -> AudioTagReadResult? {
        guard let tag = try existingTag(in: data) else { return nil }
        var result = AudioTagReadResult()
        var otherArtwork: Data?
        result.values = embeddedValues(in: tag, textFields: textFields)
        // A text-only read never extracts pictures or lyrics from the parsed frames.
        guard textFields == nil else { return result }
        for frame in tag.frames {
            readFrameContent(frame, into: &result, otherArtwork: &otherArtwork)
        }
        result.artworkData = result.artworkData ?? otherArtwork
        return result
    }

    nonisolated private static func readFrameContent(
        _ frame: ID3Frame, into result: inout AudioTagReadResult, otherArtwork: inout Data?
    ) {
        let payload = frame.payload
        if frame.id == "APIC" || frame.id == "PIC" {
            guard result.artworkData == nil, payload.count >= 5,
                  let image = artwork(in: frame) else { return }
            if image.isFrontCover {
                result.artworkData = image.data
            } else if otherArtwork == nil {
                otherArtwork = image.data
            }
        } else if frame.id == "USLT" || frame.id == "ULT", result.lyrics == nil, payload.count >= 5 {
            let encoding = payload[payload.startIndex]
            let body = payload.dropFirst(4)
            if let terminator = encodedStringTerminator(in: body, encodingByte: encoding) {
                let start = body.index(terminator, offsetBy: encoding == 1 || encoding == 2 ? 2 : 1)
                result.lyrics = decodeText(body[start...], encodingByte: encoding)
            }
        }
    }

    nonisolated private static func artwork(in frame: ID3Frame) -> (data: Data, isFrontCover: Bool)? {
        let payload = frame.payload
        let encoding = payload[payload.startIndex]
        var cursor = payload.index(after: payload.startIndex)
        if frame.id == "PIC" {
            cursor = payload.index(cursor, offsetBy: 3, limitedBy: payload.endIndex) ?? payload.endIndex
        } else if let terminator = payload[cursor...].firstIndex(of: 0) {
            cursor = payload.index(after: terminator)
        } else {
            return nil
        }
        guard cursor < payload.endIndex else { return nil }
        let pictureType = payload[cursor]
        cursor = payload.index(after: cursor)
        guard cursor < payload.endIndex,
              let terminator = encodedStringTerminator(in: payload[cursor...], encodingByte: encoding)
        else { return nil }
        let end = payload.index(terminator, offsetBy: encoding == 1 || encoding == 2 ? 2 : 1)
        guard end < payload.endIndex else { return nil }
        return (Data(payload[end...]), pictureType == 3)
    }
}

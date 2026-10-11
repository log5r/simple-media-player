import Foundation

struct MP4MetadataReadResult: Equatable, Sendable {
    var values = MediaMetadataEmbeddedValues()
    var artworkData: Data?
    var lyrics: String?
    var usedSortMetadataFallback = false
}

enum MP4MetadataReader {
    nonisolated private static let moov = Array("moov".utf8)
    nonisolated private static let udta = Array("udta".utf8)
    nonisolated private static let meta = Array("meta".utf8)
    nonisolated private static let ilst = Array("ilst".utf8)
    nonisolated private static let data = Array("data".utf8)

    /// A non-nil `textFields` reads only those text payloads, including their sort fallbacks.
    /// Artwork and lyrics payloads are skipped entirely.
    nonisolated static func read(
        from url: URL, textFields: Set<MediaMetadataEditField>? = nil
    ) throws -> MP4MetadataReadResult? {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let parser = Parser(handle: handle)
        let fileSize = try handle.seekToEnd()
        let moovBoxes = try parser.boxes(ofType: moov, in: 0..<fileSize)

        for moovBox in moovBoxes {
            var metadataBoxes = try parser.boxes(ofType: meta, in: moovBox.contentRange)
            for userDataBox in try parser.boxes(ofType: udta, in: moovBox.contentRange) {
                metadataBoxes.append(contentsOf: try parser.boxes(ofType: meta, in: userDataBox.contentRange))
            }

            for metadataBox in metadataBoxes {
                let metadataRange = metadataBox.contentRange.dropFirstBytes(4)
                for itemListBox in try parser.boxes(ofType: ilst, in: metadataRange) {
                    return try result(inItemList: itemListBox.contentRange, parser: parser, textFields: textFields)
                }
            }
        }

        return nil
    }

    /// QuickTime user-data strings and keyed (`mdta`) metadata are outside the iTunes reader's contract.
    /// Check their box headers so an ordinary missing iTunes tag does not trigger an AVFoundation load.
    nonisolated static func requiresCommonTextFallback(from url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let parser = Parser(handle: handle)
        let size = try handle.seekToEnd()
        for movie in try parser.boxes(ofType: moov, in: 0..<size) {
            var metadataBoxes = try parser.boxes(ofType: meta, in: movie.contentRange)
            for userData in try parser.boxes(ofType: udta, in: movie.contentRange) {
                let children = try parser.boxes(in: userData.contentRange)
                if children.contains(where: { $0.type.first == 0xA9 }) { return true }
                metadataBoxes += children.filter { $0.type == meta }
            }
            for metadata in metadataBoxes {
                // ISO meta is a full box; legacy QuickTime meta can start directly with child boxes.
                for range in [metadata.contentRange.dropFirstBytes(4), metadata.contentRange] {
                    let children = try parser.boxes(in: range)
                    if children.contains(where: { $0.type == Array("keys".utf8) }) { return true }
                }
            }
        }
        return false
    }

    nonisolated private static func result(
        inItemList range: Range<UInt64>,
        parser: Parser, textFields: Set<MediaMetadataEditField>?
    ) throws -> MP4MetadataReadResult {
        var result = MP4MetadataReadResult()
        var sortValues = MediaMetadataEmbeddedValues()

        for itemBox in try parser.boxes(in: range) {
            if let textFields {
                let type = MP4MetadataWriter.BoxType(itemBox.type)
                guard MP4MetadataWriter.editableItemFields[type].map(textFields.contains) == true else { continue }
            }
            guard let dataBox = try parser.boxes(ofType: data, in: itemBox.contentRange).first else {
                continue
            }
            let payloadRange = dataBox.contentRange.dropFirstBytes(8)

            try readTextPayload(itemBox.type, range: payloadRange, parser: parser, values: &result.values)
            try readNumericPayload(itemBox.type, range: payloadRange, parser: parser, values: &result.values)
            try readOtherPayload(
                itemBox.type, range: payloadRange, parser: parser, result: &result, sortValues: &sortValues
            )
        }

        if result.values.title == nil, sortValues.title != nil {
            result.values.title = sortValues.title
            result.usedSortMetadataFallback = true
        }
        if result.values.artist == nil, sortValues.artist != nil {
            result.values.artist = sortValues.artist
            result.usedSortMetadataFallback = true
        }
        if result.values.album == nil, sortValues.album != nil {
            result.values.album = sortValues.album
            result.usedSortMetadataFallback = true
        }
        if result.values.albumArtist == nil, sortValues.albumArtist != nil {
            result.values.albumArtist = sortValues.albumArtist
            result.usedSortMetadataFallback = true
        }
        if result.values.composer == nil, sortValues.composer != nil {
            result.values.composer = sortValues.composer
            result.usedSortMetadataFallback = true
        }

        return result
    }

    nonisolated private static func readTextPayload(
        _ type: BoxType, range: Range<UInt64>, parser: Parser, values: inout MediaMetadataEmbeddedValues
    ) throws {
        switch type {
        case [0xA9, 0x6E, 0x61, 0x6D]:
            values.title = try parser.string(in: range)
        case [0xA9, 0x41, 0x52, 0x54]:
            values.artist = try parser.string(in: range)
        case [0xA9, 0x61, 0x6C, 0x62]:
            values.album = try parser.string(in: range)
        case [0xA9, 0x67, 0x65, 0x6E]:
            values.genre = try parser.string(in: range)
        case [0xA9, 0x64, 0x61, 0x79]:
            values.year = normalizedYear(try parser.string(in: range))
        case [0xA9, 0x63, 0x6D, 0x74]:
            values.comment = try parser.string(in: range)
        case Array("aART".utf8):
            values.albumArtist = try parser.string(in: range)
        case [0xA9, 0x77, 0x72, 0x74]:
            values.composer = try parser.string(in: range)
        default: break
        }
    }

    nonisolated private static func readNumericPayload(
        _ type: BoxType, range: Range<UInt64>, parser: Parser, values: inout MediaMetadataEmbeddedValues
    ) throws {
        switch type {
        case Array("trkn".utf8):
            values.trackNumber = try parser.numberPairString(in: range)
        case Array("disk".utf8):
            values.discNumber = try parser.numberPairString(in: range)
        case Array("cpil".utf8):
            values.isCompilation = try parser.bool(in: range)
        default: break
        }
    }

    nonisolated private static func readOtherPayload(
        _ type: BoxType, range: Range<UInt64>, parser: Parser,
        result: inout MP4MetadataReadResult, sortValues: inout MediaMetadataEmbeddedValues
    ) throws {
        switch type {
        case Array("covr".utf8):
            result.artworkData = try parser.rawData(in: range)
        case [0xA9, 0x6C, 0x79, 0x72]:
            result.lyrics = try parser.string(in: range)
        case Array("sonm".utf8):
            sortValues.title = try parser.string(in: range)
        case Array("soar".utf8):
            sortValues.artist = try parser.string(in: range)
        case Array("soal".utf8):
            sortValues.album = try parser.string(in: range)
        case Array("soaa".utf8):
            sortValues.albumArtist = try parser.string(in: range)
        case Array("soco".utf8):
            sortValues.composer = try parser.string(in: range)
        default: break
        }
    }

    nonisolated private static func normalizedYear(_ value: String?) -> String? {
        guard let value else { return nil }
        let prefix = value.prefix(4)
        guard prefix.count == 4, prefix.allSatisfy(\.isNumber) else { return value }
        guard value.count == 4 || value.dropFirst(4).first.map({ "-:/".contains($0) }) == true else {
            return value
        }
        return String(prefix)
    }
}

struct MP4TitleReader {
    nonisolated static func title(in url: URL) throws -> String? {
        try MP4MetadataReader.read(from: url)?.values.title
    }
}

private struct Parser {
    let handle: FileHandle

    nonisolated func boxes(in range: Range<UInt64>) throws -> [Box] {
        var boxes: [Box] = []
        var offset = range.lowerBound

        while offset + 8 <= range.upperBound {
            // Fragmented files can have many top-level boxes, so cancelled readers stop between them.
            try Task.checkCancellation()
            guard let box = try box(at: offset, limit: range.upperBound) else {
                break
            }
            boxes.append(box)

            guard box.totalRange.upperBound > offset else {
                break
            }
            offset = box.totalRange.upperBound
        }

        return boxes
    }

    nonisolated func boxes(ofType requestedType: BoxType, in range: Range<UInt64>) throws -> [Box] {
        try boxes(in: range).filter { $0.type == requestedType }
    }

    nonisolated func string(in range: Range<UInt64>) throws -> String? {
        guard range.lowerBound < range.upperBound else { return nil }
        let byteCount = range.upperBound - range.lowerBound
        guard byteCount <= UInt64(Int.max) else { return nil }

        try handle.seek(toOffset: range.lowerBound)
        guard let data = try handle.read(upToCount: Int(byteCount)), data.isEmpty == false else {
            return nil
        }

        let trimmedData = data.trimmingNullTerminators()
        let value = String(data: trimmedData, encoding: .utf8)
            ?? String(data: trimmedData, encoding: .utf16BigEndian)
            ?? String(data: trimmedData, encoding: .utf16LittleEndian)

        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    nonisolated func rawData(in range: Range<UInt64>) throws -> Data? {
        guard range.lowerBound < range.upperBound else { return nil }
        let byteCount = range.upperBound - range.lowerBound
        guard byteCount <= UInt64(Int.max) else { return nil }

        try handle.seek(toOffset: range.lowerBound)
        return try handle.read(upToCount: Int(byteCount))
    }

    nonisolated func numberPairString(in range: Range<UInt64>) throws -> String? {
        guard let data = try rawData(in: range), data.count >= 6 else { return nil }
        let current = UInt16(data[data.startIndex + 2]) << 8 | UInt16(data[data.startIndex + 3])
        let total = UInt16(data[data.startIndex + 4]) << 8 | UInt16(data[data.startIndex + 5])
        guard current > 0 else { return nil }
        return total > 0 ? "\(current)/\(total)" : "\(current)"
    }

    nonisolated func bool(in range: Range<UInt64>) throws -> Bool? {
        try rawData(in: range)?.last.map { $0 != 0 }
    }

    nonisolated private func box(at offset: UInt64, limit: UInt64) throws -> Box? {
        try handle.seek(toOffset: offset)
        guard let header = try handle.read(upToCount: 8), header.count == 8 else {
            return nil
        }

        let compactSize = header.uint32(at: 0)
        let type = Array(header[4..<8])
        var headerSize: UInt64 = 8
        let size: UInt64

        if compactSize == 1 {
            guard offset + 16 <= limit,
                  let extendedHeader = try handle.read(upToCount: 8),
                  extendedHeader.count == 8
            else { return nil }
            headerSize = 16
            size = extendedHeader.uint64(at: 0)
        } else if compactSize == 0 {
            size = limit - offset
        } else {
            size = UInt64(compactSize)
        }

        guard size >= headerSize else { return nil }
        let end = min(offset + size, limit)
        guard offset + headerSize <= end else { return nil }

        return Box(
            type: type,
            totalRange: offset..<end,
            contentRange: (offset + headerSize)..<end
        )
    }
}

private struct Box {
    let type: BoxType
    let totalRange: Range<UInt64>
    let contentRange: Range<UInt64>
}

private typealias BoxType = [UInt8]

private extension Range where Bound == UInt64 {
    nonisolated func dropFirstBytes(_ count: UInt64) -> Range<UInt64> {
        Swift.min(lowerBound + count, upperBound)..<upperBound
    }
}

private extension Data {
    nonisolated func uint32(at offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset]) << 24
            | UInt32(self[startIndex + offset + 1]) << 16
            | UInt32(self[startIndex + offset + 2]) << 8
            | UInt32(self[startIndex + offset + 3])
    }

    nonisolated func uint64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { result, index in
            (result << 8) | UInt64(self[startIndex + offset + index])
        }
    }

    nonisolated func trimmingNullTerminators() -> Data {
        var endIndex = self.endIndex
        while endIndex > startIndex, self[index(before: endIndex)] == 0 {
            endIndex = index(before: endIndex)
        }
        return self[startIndex..<endIndex]
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

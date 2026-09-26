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

    nonisolated static func read(from url: URL) throws -> MP4MetadataReadResult? {
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
                    return try result(inItemList: itemListBox.contentRange, parser: parser)
                }
            }
        }

        return nil
    }

    nonisolated private static func result(
        inItemList range: Range<UInt64>,
        parser: Parser
    ) throws -> MP4MetadataReadResult {
        var result = MP4MetadataReadResult()
        var sortTitle: String?
        var sortArtist: String?
        var sortAlbum: String?
        var sortAlbumArtist: String?
        var sortComposer: String?

        for itemBox in try parser.boxes(in: range) {
            guard let dataBox = try parser.boxes(ofType: data, in: itemBox.contentRange).first else {
                continue
            }
            let payloadRange = dataBox.contentRange.dropFirstBytes(8)

            switch itemBox.type {
            case [0xA9, 0x6E, 0x61, 0x6D]:
                result.values.title = try parser.string(in: payloadRange)
            case [0xA9, 0x41, 0x52, 0x54]:
                result.values.artist = try parser.string(in: payloadRange)
            case [0xA9, 0x61, 0x6C, 0x62]:
                result.values.album = try parser.string(in: payloadRange)
            case [0xA9, 0x67, 0x65, 0x6E]:
                result.values.genre = try parser.string(in: payloadRange)
            case [0xA9, 0x64, 0x61, 0x79]:
                result.values.year = normalizedYear(try parser.string(in: payloadRange))
            case Array("trkn".utf8):
                result.values.trackNumber = try parser.numberPairString(in: payloadRange)
            case [0xA9, 0x63, 0x6D, 0x74]:
                result.values.comment = try parser.string(in: payloadRange)
            case Array("aART".utf8):
                result.values.albumArtist = try parser.string(in: payloadRange)
            case [0xA9, 0x77, 0x72, 0x74]:
                result.values.composer = try parser.string(in: payloadRange)
            case Array("disk".utf8):
                result.values.discNumber = try parser.numberPairString(in: payloadRange)
            case Array("cpil".utf8):
                result.values.isCompilation = try parser.bool(in: payloadRange)
            case Array("covr".utf8):
                result.artworkData = try parser.rawData(in: payloadRange)
            case [0xA9, 0x6C, 0x79, 0x72]:
                result.lyrics = try parser.string(in: payloadRange)
            case Array("sonm".utf8):
                sortTitle = try parser.string(in: payloadRange)
            case Array("soar".utf8):
                sortArtist = try parser.string(in: payloadRange)
            case Array("soal".utf8):
                sortAlbum = try parser.string(in: payloadRange)
            case Array("soaa".utf8):
                sortAlbumArtist = try parser.string(in: payloadRange)
            case Array("soco".utf8):
                sortComposer = try parser.string(in: payloadRange)
            default:
                continue
            }
        }

        if result.values.title == nil, sortTitle != nil {
            result.values.title = sortTitle
            result.usedSortMetadataFallback = true
        }
        if result.values.artist == nil, sortArtist != nil {
            result.values.artist = sortArtist
            result.usedSortMetadataFallback = true
        }
        if result.values.album == nil, sortAlbum != nil {
            result.values.album = sortAlbum
            result.usedSortMetadataFallback = true
        }
        if result.values.albumArtist == nil, sortAlbumArtist != nil {
            result.values.albumArtist = sortAlbumArtist
            result.usedSortMetadataFallback = true
        }
        if result.values.composer == nil, sortComposer != nil {
            result.values.composer = sortComposer
            result.usedSortMetadataFallback = true
        }

        return result
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

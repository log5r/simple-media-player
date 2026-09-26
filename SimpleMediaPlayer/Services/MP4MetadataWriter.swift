import Foundation

enum MP4MetadataWriter {
    nonisolated private static let editableItemTypes: Set<BoxType> = [
        BoxType([0xA9, 0x6E, 0x61, 0x6D]),
        BoxType([0xA9, 0x41, 0x52, 0x54]),
        BoxType([0xA9, 0x61, 0x6C, 0x62]),
        BoxType([0xA9, 0x67, 0x65, 0x6E]),
        BoxType("gnre"),
        BoxType([0xA9, 0x64, 0x61, 0x79]),
        BoxType("trkn"),
        BoxType([0xA9, 0x63, 0x6D, 0x74]),
        BoxType("aART"),
        BoxType([0xA9, 0x77, 0x72, 0x74]),
        BoxType("disk"),
        BoxType("cpil")
    ]
    nonisolated private static let artworkItemType = BoxType("covr")
    nonisolated private static let lyricsItemType = BoxType([0xA9, 0x6C, 0x79, 0x72])

    nonisolated private static let containerTypes: Set<BoxType> = [
        BoxType("moov"),
        BoxType("trak"),
        BoxType("mdia"),
        BoxType("minf"),
        BoxType("stbl"),
        BoxType("edts"),
        BoxType("dinf"),
        BoxType("udta")
    ]

    nonisolated static func canWriteMetadata(to url: URL) -> Bool {
        ["m4a", "m4v", "mp4", "mov"].contains(url.pathExtension.lowercased())
    }

    nonisolated static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        guard canWriteMetadata(to: url) else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }

        try MediaFileRewriter.rewrite(at: url) { source, output, fileSize in
            let topLevelBoxes = try fileBoxes(in: source, fileSize: fileSize)
            guard let moovBox = topLevelBoxes.first(where: { $0.type == BoxType("moov") }) else {
                throw MediaMetadataEditError.unsupportedMP4MetadataLayout
            }
            let contentSize = moovBox.contentRange.upperBound - moovBox.contentRange.lowerBound
            let originalSize = moovBox.totalRange.upperBound - moovBox.totalRange.lowerBound
            guard contentSize <= UInt64(Int.max), originalSize <= UInt64(Int.max) else {
                throw MediaMetadataEditError.unsupportedMP4MetadataLayout
            }
            let data = try MediaFileRewriter.read(
                from: source,
                at: moovBox.contentRange.lowerBound,
                count: Int(contentSize)
            )
            let rebuiltMoovContent = try rewriteMoovContent(draft, in: 0..<data.count, data: data)
            var rebuiltMoovBox = makeBox(type: moovBox.type, content: rebuiltMoovContent)
            let oldMoovSize = Int(originalSize)

            if rebuiltMoovBox.count < oldMoovSize, oldMoovSize - rebuiltMoovBox.count >= 8 {
                let paddingSize = oldMoovSize - rebuiltMoovBox.count
                rebuiltMoovBox = makeBox(
                    type: moovBox.type,
                    content: rebuiltMoovContent + makeFreeBox(size: paddingSize)
                )
            }
            let sizeDelta = rebuiltMoovBox.count - oldMoovSize
            if sizeDelta != 0 {
                rebuiltMoovBox = try adjustingChunkOffsets(
                    inMoovBox: rebuiltMoovBox,
                    by: Int64(sizeDelta),
                    startingAt: moovBox.totalRange.upperBound
                )
            }

            try MediaFileRewriter.copy(from: source, range: 0..<moovBox.totalRange.lowerBound, to: output)
            try output.write(contentsOf: rebuiltMoovBox)
            try MediaFileRewriter.copy(from: source, range: moovBox.totalRange.upperBound..<fileSize, to: output)
        }
    }

    nonisolated private static func rewriteMoovContent(
        _ draft: MediaMetadataEditDraft,
        in range: Range<Int>,
        data: Data
    ) throws -> Data {
        try rewriteContainer(
            in: range,
            data: data,
            targetType: BoxType("udta"),
            makeReplacement: { udtaBox in
                if let udtaBox {
                    let rewrittenContent = try rewriteUdtaContent(draft, in: udtaBox.contentRange, data: data)
                    return makeBox(type: udtaBox.type, content: rewrittenContent)
                }
                return makeBox(type: BoxType("udta"), content: try makeMetaBox(draft))
            }
        )
    }

    nonisolated private static func rewriteUdtaContent(
        _ draft: MediaMetadataEditDraft,
        in range: Range<Int>,
        data: Data
    ) throws -> Data {
        try rewriteContainer(
            in: range,
            data: data,
            targetType: BoxType("meta"),
            makeReplacement: { metaBox in
                if let metaBox {
                    return try rewriteMetaBox(draft, box: metaBox, data: data)
                }
                return try makeMetaBox(draft)
            }
        )
    }

    nonisolated private static func rewriteMetaBox(
        _ draft: MediaMetadataEditDraft,
        box: MP4Box,
        data: Data
    ) throws -> Data {
        let content = data[box.contentRange]
        guard content.count >= 4 else {
            throw MediaMetadataEditError.invalidMP4Metadata
        }

        let fullBoxHeader = Data(content.prefix(4))
        let childRange = (box.contentRange.lowerBound + 4)..<box.contentRange.upperBound
        let rewrittenChildren = try rewriteContainer(
            in: childRange,
            data: data,
            targetType: BoxType("ilst"),
            makeReplacement: { ilstBox in
                if let ilstBox {
                    return try makeIlstBox(draft, existingContentRange: ilstBox.contentRange, data: data)
                }
                return try makeIlstBox(draft, existingContentRange: nil, data: data)
            }
        )

        return makeBox(type: box.type, content: fullBoxHeader + rewrittenChildren)
    }

    nonisolated private static func makeMetaBox(_ draft: MediaMetadataEditDraft) throws -> Data {
        makeBox(
            type: BoxType("meta"),
            content: Data([0, 0, 0, 0]) + (try makeIlstBox(draft, existingContentRange: nil, data: Data()))
        )
    }

    nonisolated private static func makeIlstBox(
        _ draft: MediaMetadataEditDraft,
        existingContentRange: Range<Int>?,
        data: Data
    ) throws -> Data {
        var content = Data()

        if let existingContentRange {
            let itemBoxes = try boxes(in: existingContentRange, data: data)
            for itemBox in itemBoxes where shouldPreserve(itemBox.type, for: draft) {
                content.append(data[itemBox.totalRange])
            }
        }

        for item in metadataItems(for: draft) {
            content.append(makeMetadataItemBox(type: item.type, dataType: item.dataType, payload: item.payload))
        }

        return makeBox(type: BoxType("ilst"), content: content)
    }

    nonisolated private static func metadataItems(for draft: MediaMetadataEditDraft) -> [MP4MetadataItem] {
        var items: [MP4MetadataItem] = []
        if draft.editsTextMetadata {
            appendTextItem(type: BoxType([0xA9, 0x6E, 0x61, 0x6D]), value: draft.title, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x41, 0x52, 0x54]), value: draft.artist, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x61, 0x6C, 0x62]), value: draft.album, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x67, 0x65, 0x6E]), value: draft.genre, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x64, 0x61, 0x79]), value: draft.year, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x63, 0x6D, 0x74]), value: draft.comment, to: &items)
            appendTextItem(type: BoxType("aART"), value: draft.albumArtist, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x77, 0x72, 0x74]), value: draft.composer, to: &items)
            if let trackPayload = numberPairPayload(draft.trackNumber) {
                items.append(MP4MetadataItem(type: BoxType("trkn"), dataType: 0, payload: trackPayload))
            }
            if let discPayload = numberPairPayload(draft.discNumber) {
                items.append(MP4MetadataItem(type: BoxType("disk"), dataType: 0, payload: discPayload))
            }
            if draft.isCompilation {
                items.append(MP4MetadataItem(type: BoxType("cpil"), dataType: 21, payload: Data([1])))
            }
        }
        if draft.editsArtwork, let artworkData = draft.artworkData {
            let dataType: UInt32 = artworkData.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? 14 : 13
            items.append(MP4MetadataItem(type: artworkItemType, dataType: dataType, payload: artworkData))
        }
        if draft.editsLyrics, let lyrics = normalized(draft.lyrics) {
            items.append(MP4MetadataItem(type: lyricsItemType, dataType: 1, payload: Data(lyrics.utf8)))
        }
        return items
    }

    nonisolated private static func shouldPreserve(_ type: BoxType, for draft: MediaMetadataEditDraft) -> Bool {
        if draft.editsTextMetadata, editableItemTypes.contains(type) {
            return false
        }
        if draft.editsArtwork, type == artworkItemType {
            return false
        }
        return draft.editsLyrics == false || type != lyricsItemType
    }

    nonisolated private static func appendTextItem(type: BoxType, value: String, to items: inout [MP4MetadataItem]) {
        guard let value = normalized(value) else { return }
        items.append(MP4MetadataItem(type: type, dataType: 1, payload: Data(value.utf8)))
    }

    nonisolated private static func numberPairPayload(_ value: String) -> Data? {
        guard let value = normalized(value) else { return nil }
        let components = value.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let firstText = components.first,
              let first = UInt16(firstText),
              first > 0
        else { return nil }
        let second = components.dropFirst().first.flatMap(UInt16.init) ?? 0

        var payload = Data([0, 0])
        payload.append(uint16Data(first))
        payload.append(uint16Data(second))
        payload.append(contentsOf: [0, 0])
        return payload
    }

    nonisolated private static func makeMetadataItemBox(type: BoxType, dataType: UInt32, payload: Data) -> Data {
        var dataPayload = uint32Data(dataType)
        dataPayload.append(contentsOf: [0, 0, 0, 0])
        dataPayload.append(payload)
        return makeBox(type: type, content: makeBox(type: BoxType("data"), content: dataPayload))
    }

    nonisolated private static func rewriteContainer(
        in range: Range<Int>,
        data: Data,
        targetType: BoxType,
        makeReplacement: (MP4Box?) throws -> Data
    ) throws -> Data {
        let childBoxes = try boxes(in: range, data: data)
        var content = Data()
        var offset = range.lowerBound
        var didReplace = false

        for box in childBoxes {
            guard offset <= box.totalRange.lowerBound else {
                throw MediaMetadataEditError.invalidMP4Metadata
            }

            content.append(data[offset..<box.totalRange.lowerBound])
            if box.type == targetType {
                content.append(try makeReplacement(box))
                didReplace = true
            } else {
                content.append(data[box.totalRange])
            }
            offset = box.totalRange.upperBound
        }

        content.append(data[offset..<range.upperBound])

        if didReplace == false {
            content.append(try makeReplacement(nil))
        }

        return content
    }

    nonisolated private static func adjustingChunkOffsets(
        inMoovBox moovBox: Data,
        by delta: Int64,
        startingAt threshold: UInt64
    ) throws -> Data {
        var data = moovBox
        try adjustChunkOffsets(in: &data, range: 8..<data.count, delta: delta, threshold: threshold)
        return data
    }

    nonisolated private static func adjustChunkOffsets(
        in data: inout Data,
        range: Range<Int>,
        delta: Int64,
        threshold: UInt64
    ) throws {
        let childBoxes = try boxes(in: range, data: data)

        for box in childBoxes {
            if box.type == BoxType("stco") {
                try adjustStco(in: &data, box: box, delta: delta, threshold: threshold)
            } else if box.type == BoxType("co64") {
                try adjustCo64(in: &data, box: box, delta: delta, threshold: threshold)
            } else if containerTypes.contains(box.type) {
                try adjustChunkOffsets(in: &data, range: box.contentRange, delta: delta, threshold: threshold)
            } else if box.type == BoxType("meta"), box.contentRange.count >= 4 {
                try adjustChunkOffsets(
                    in: &data,
                    range: (box.contentRange.lowerBound + 4)..<box.contentRange.upperBound,
                    delta: delta,
                    threshold: threshold
                )
            }
        }
    }

    nonisolated private static func adjustStco(
        in data: inout Data,
        box: MP4Box,
        delta: Int64,
        threshold: UInt64
    ) throws {
        guard box.contentRange.count >= 8 else {
            throw MediaMetadataEditError.invalidMP4Metadata
        }
        let countOffset = box.contentRange.lowerBound + 4
        let entryCount = Int(readUInt32(in: data, at: countOffset))
        let entriesStart = countOffset + 4
        guard entriesStart + entryCount * 4 <= box.contentRange.upperBound else {
            throw MediaMetadataEditError.invalidMP4Metadata
        }

        for index in 0..<entryCount {
            let offset = entriesStart + index * 4
            let current = readUInt32(in: data, at: offset)
            guard UInt64(current) >= threshold else { continue }
            let adjusted = Int64(current) + delta
            guard adjusted >= 0, adjusted <= Int64(UInt32.max) else {
                throw MediaMetadataEditError.unsupportedMP4MetadataLayout
            }
            writeUInt32(UInt32(adjusted), in: &data, at: offset)
        }
    }

    nonisolated private static func adjustCo64(
        in data: inout Data,
        box: MP4Box,
        delta: Int64,
        threshold: UInt64
    ) throws {
        guard box.contentRange.count >= 8 else {
            throw MediaMetadataEditError.invalidMP4Metadata
        }
        let countOffset = box.contentRange.lowerBound + 4
        let entryCount = Int(readUInt32(in: data, at: countOffset))
        let entriesStart = countOffset + 4
        guard entriesStart + entryCount * 8 <= box.contentRange.upperBound else {
            throw MediaMetadataEditError.invalidMP4Metadata
        }

        for index in 0..<entryCount {
            let offset = entriesStart + index * 8
            let current = readUInt64(in: data, at: offset)
            guard current >= threshold else { continue }
            guard delta >= 0 || current >= UInt64(-delta) else {
                throw MediaMetadataEditError.unsupportedMP4MetadataLayout
            }
            let (adjusted, overflow) = delta >= 0
                ? current.addingReportingOverflow(UInt64(delta))
                : current.subtractingReportingOverflow(UInt64(-delta))
            guard overflow == false else {
                throw MediaMetadataEditError.unsupportedMP4MetadataLayout
            }
            writeUInt64(adjusted, in: &data, at: offset)
        }
    }

    nonisolated private static func fileBoxes(in handle: FileHandle, fileSize: UInt64) throws -> [MP4FileBox] {
        var result: [MP4FileBox] = []
        var offset: UInt64 = 0
        while fileSize - offset >= 8 {
            let header = try MediaFileRewriter.read(from: handle, at: offset, count: 8)
            let compactSize = readUInt32(in: header, at: 0)
            let type = BoxType(header[4..<8])
            let headerSize: UInt64
            let size: UInt64
            if compactSize == 1 {
                guard fileSize - offset >= 16 else { throw MediaMetadataEditError.invalidMP4Metadata }
                let extendedHeader = try MediaFileRewriter.read(from: handle, at: offset + 8, count: 8)
                headerSize = 16
                size = readUInt64(in: extendedHeader, at: 0)
            } else {
                headerSize = 8
                size = compactSize == 0 ? fileSize - offset : UInt64(compactSize)
            }
            guard size >= headerSize, size <= fileSize - offset else {
                throw MediaMetadataEditError.invalidMP4Metadata
            }
            result.append(MP4FileBox(
                type: type,
                totalRange: offset..<(offset + size),
                contentRange: (offset + headerSize)..<(offset + size)
            ))
            offset += size
        }
        return result
    }

    nonisolated private static func boxes(in range: Range<Int>, data: Data) throws -> [MP4Box] {
        var boxes: [MP4Box] = []
        var offset = range.lowerBound

        while offset + 8 <= range.upperBound {
            let compactSize = readUInt32(in: data, at: offset)
            let type = BoxType(data[(offset + 4)..<(offset + 8)])
            let headerSize: Int
            let size: Int

            if compactSize == 1 {
                guard offset + 16 <= range.upperBound else {
                    throw MediaMetadataEditError.invalidMP4Metadata
                }
                let extendedSize = readUInt64(in: data, at: offset + 8)
                guard extendedSize <= UInt64(Int.max) else {
                    throw MediaMetadataEditError.unsupportedMP4MetadataLayout
                }
                headerSize = 16
                size = Int(extendedSize)
            } else if compactSize == 0 {
                headerSize = 8
                size = range.upperBound - offset
            } else {
                headerSize = 8
                size = Int(compactSize)
            }

            guard size >= headerSize, size <= range.upperBound - offset else {
                throw MediaMetadataEditError.invalidMP4Metadata
            }

            boxes.append(MP4Box(
                type: type,
                totalRange: offset..<(offset + size),
                contentRange: (offset + headerSize)..<(offset + size)
            ))
            offset += size
        }

        return boxes
    }

    nonisolated private static func makeBox(type: BoxType, content: Data) -> Data {
        var box = Data()
        let size = content.count + 8
        box.append(uint32Data(UInt32(size)))
        box.append(type.data)
        box.append(content)
        return box
    }

    nonisolated private static func makeFreeBox(size: Int) -> Data {
        guard size >= 8 else { return Data() }
        return makeBox(type: BoxType("free"), content: Data(repeating: 0, count: size - 8))
    }

    nonisolated private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    nonisolated private static func readUInt64(in data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { result, index in
            (result << 8) | UInt64(data[offset + index])
        }
    }

    nonisolated private static func writeUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    nonisolated private static func writeUInt64(_ value: UInt64, in data: inout Data, at offset: Int) {
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> ((7 - index) * 8)) & 0xFF)
        }
    }

    nonisolated private static func uint32Data(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    nonisolated private static func uint16Data(_ value: UInt16) -> Data {
        Data([
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}

nonisolated private struct MP4MetadataItem: Sendable {
    let type: BoxType
    let dataType: UInt32
    let payload: Data
}

nonisolated private struct MP4Box: Sendable {
    let type: BoxType
    let totalRange: Range<Int>
    let contentRange: Range<Int>
}

nonisolated private struct MP4FileBox: Sendable {
    let type: BoxType
    let totalRange: Range<UInt64>
    let contentRange: Range<UInt64>
}

nonisolated private struct BoxType: Hashable, Equatable, Sendable {
    let data: Data

    nonisolated init(_ string: String) {
        self.data = Data(string.utf8)
    }

    nonisolated init(_ bytes: [UInt8]) {
        self.data = Data(bytes)
    }

    nonisolated init(_ bytes: Data.SubSequence) {
        self.data = Data(bytes)
    }

    nonisolated static func == (lhs: BoxType, rhs: BoxType) -> Bool {
        lhs.data == rhs.data
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(data)
    }
}

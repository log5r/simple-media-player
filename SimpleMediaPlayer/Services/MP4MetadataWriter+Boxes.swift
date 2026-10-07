import Foundation

extension MP4MetadataWriter {
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

    nonisolated static func rewriteContainer(
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

    nonisolated static func adjustingChunkOffsets(
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

    nonisolated static func fileBoxes(in handle: FileHandle, fileSize: UInt64) throws -> [MP4FileBox] {
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

    nonisolated static func boxes(in range: Range<Int>, data: Data) throws -> [MP4Box] {
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

    nonisolated struct MP4Box: Sendable {
        let type: BoxType
        let totalRange: Range<Int>
        let contentRange: Range<Int>
    }

    nonisolated struct MP4FileBox: Sendable {
        let type: BoxType
        let totalRange: Range<UInt64>
        let contentRange: Range<UInt64>
    }

    nonisolated struct BoxType: Hashable, Equatable, Sendable {
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
}

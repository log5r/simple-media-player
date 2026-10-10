import Foundation

nonisolated enum FLACMetadataWriter {
    private struct Block {
        let type: UInt8
        let range: Range<UInt64>
        let payload: Range<UInt64>
    }
    /// A block to write: new `data`, or the payload at `source` in the original file.
    private struct OutputBlock {
        let type: UInt8
        var data: Data?
        var source: Range<UInt64>?
    }
    private static let paddingType: UInt8 = 1
    private static let maxBlockLength: UInt64 = 0xFFFFFF

    static func canWriteMetadata(to url: URL) -> Bool {
        url.pathExtension.lowercased() == "flac"
    }

    static func read(from url: URL) throws -> AudioTagReadResult {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let size = try source.seekToEnd()
        let blocks = try parse(source, size: size)
        var result = AudioTagReadResult()
        if let comment = blocks.first(where: { $0.type == 4 }) {
            result = XiphMetadata.read(try XiphMetadata.parse(readPayload(comment, source: source)))
        }
        let pictures = blocks.filter { $0.type == 6 }
        let front = try pictures.first {
            guard $0.payload.count >= 4 else { throw MediaMetadataEditError.invalidAudioMetadata }
            let header = try MediaFileRewriter.read(from: source, at: $0.payload.lowerBound, count: 4)
            return XiphMetadata.pictureType(header) == 3
        }
        if let picture = front ?? (result.artworkData == nil ? pictures.first : nil) {
            result.artworkData = try XiphMetadata.pictureData(readPayload(picture, source: source))
        }
        return result
    }

    static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        guard canWriteMetadata(to: url) else { throw MediaMetadataEditError.unsupportedFileFormat }
        try MediaFileRewriter.update(at: url) { source, size in
            let blocks = try parse(source, size: size)
            return try inPlaceEdit(outputBlocks(for: draft, blocks: blocks, source: source),
                                   metadataEnd: blocks.last!.range.upperBound, source: source)
        } rewrite: { source, output, size in
            let blocks = try parse(source, size: size)
            let outputBlocks = try outputBlocks(for: draft, blocks: blocks, source: source)
            try output.write(contentsOf: Data("fLaC".utf8))
            for (index, block) in outputBlocks.enumerated() {
                try output.write(contentsOf: header(block, isLast: index == outputBlocks.count - 1))
                if let data = block.data {
                    try output.write(contentsOf: data)
                } else if let range = block.source {
                    try MediaFileRewriter.copy(from: source, range: range, to: output)
                }
            }
            try MediaFileRewriter.copy(from: source, range: blocks.last!.range.upperBound..<size, to: output)
        }
    }

    /// The new metadata blocks: replaced comment and front cover, with every other block copied from `source`.
    private static func outputBlocks(
        for draft: MediaMetadataEditDraft, blocks: [Block], source: FileHandle
    ) throws -> [OutputBlock] {
        let oldComment = try blocks.first(where: { $0.type == 4 }).map {
            try XiphMetadata.parse(readPayload($0, source: source))
        } ?? XiphMetadata.Comment(vendor: Data("SimpleMediaPlayer".utf8), fields: [])
        let commentData = try XiphMetadata.encode(XiphMetadata.updating(oldComment, with: draft))
        let comment = OutputBlock(type: 4, data: commentData)
        var outputBlocks: [OutputBlock] = []
        var didWriteComment = false
        for block in blocks {
            if block.type == 4 {
                if didWriteComment == false {
                    outputBlocks.append(comment)
                    didWriteComment = true
                }
            } else if block.type == 6 && draft.editsArtwork {
                guard block.payload.count >= 4 else { throw MediaMetadataEditError.invalidAudioMetadata }
                let header = try MediaFileRewriter.read(from: source, at: block.payload.lowerBound, count: 4)
                if XiphMetadata.pictureType(header) == 3 { continue }
                outputBlocks.append(OutputBlock(type: block.type, source: block.payload))
            } else {
                outputBlocks.append(OutputBlock(type: block.type, source: block.payload))
            }
        }
        if didWriteComment == false { outputBlocks.append(comment) }
        if draft.editsArtwork, let artwork = draft.artworkData {
            outputBlocks.append(OutputBlock(type: 6, data: try XiphMetadata.pictureBlock(artwork)))
        }
        return outputBlocks
    }

    /// Rewrites the metadata blocks within `0..<metadataEnd` when they fit without the existing PADDING blocks;
    /// a new PADDING block at the end fills any remaining space.
    private static func inPlaceEdit(
        _ outputBlocks: [OutputBlock], metadataEnd: UInt64, source: FileHandle
    ) throws -> MediaFileRewriter.InPlaceEdit? {
        var blocks = outputBlocks.filter { $0.type != paddingType }
        let size = try blocks.reduce(UInt64(4)) { try $0 + 4 + length(of: $1) }
        if size != metadataEnd {
            guard size + 4 <= metadataEnd, metadataEnd - size - 4 <= maxBlockLength else { return nil }
            blocks.append(OutputBlock(type: paddingType, data: Data(count: Int(metadataEnd - size - 4))))
        }
        var data = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            data.append(try header(block, isLast: index == blocks.count - 1))
            if let payload = block.data {
                data.append(payload)
            } else if let range = block.source {
                data.append(try MediaFileRewriter.read(from: source, at: range.lowerBound, count: range.count))
            }
        }
        return MediaFileRewriter.InPlaceEdit(offset: 0, originalLength: metadataEnd, data: data)
    }

    private static func length(of block: OutputBlock) throws -> UInt64 {
        let length = block.data.map { UInt64($0.count) } ?? (block.source!.upperBound - block.source!.lowerBound)
        guard length <= maxBlockLength else { throw MediaMetadataEditError.invalidAudioMetadata }
        return length
    }

    private static func header(_ block: OutputBlock, isLast: Bool) throws -> Data {
        let length = try length(of: block)
        let last: UInt8 = isLast ? 0x80 : 0
        return Data([last | block.type, UInt8(length >> 16), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
    }

    private static func parse(_ source: FileHandle, size: UInt64) throws -> [Block] {
        guard size >= 8, try MediaFileRewriter.read(from: source, at: 0, count: 4) == Data("fLaC".utf8) else {
            throw MediaMetadataEditError.invalidAudioMetadata
        }
        var blocks: [Block] = []
        var offset: UInt64 = 4
        while true {
            guard offset <= size - 4 else { throw MediaMetadataEditError.invalidAudioMetadata }
            let header = try MediaFileRewriter.read(from: source, at: offset, count: 4)
            let length = UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            guard length <= size - offset - 4, header[0] & 0x7f != 0x7f else {
                throw MediaMetadataEditError.invalidAudioMetadata
            }
            let end = offset + 4 + length
            blocks.append(Block(type: header[0] & 0x7f, range: offset..<end, payload: (offset + 4)..<end))
            offset = end
            if header[0] & 0x80 != 0 { break }
        }
        guard blocks.first?.type == 0, blocks.first?.payload.count == 34 else {
            throw MediaMetadataEditError.invalidAudioMetadata
        }
        return blocks
    }

    private static func readPayload(_ block: Block, source: FileHandle) throws -> Data {
        try MediaFileRewriter.read(from: source, at: block.payload.lowerBound, count: Int(block.payload.count))
    }
}

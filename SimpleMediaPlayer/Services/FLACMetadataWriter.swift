import Foundation

nonisolated enum FLACMetadataWriter {
    private struct Block {
        let type: UInt8
        let range: Range<UInt64>
        let payload: Range<UInt64>
    }

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
        try MediaFileRewriter.rewrite(at: url) { source, output, size in
            let blocks = try parse(source, size: size)
            var replacements: [(UInt8, Data?)] = []
            let oldComment = try blocks.first(where: { $0.type == 4 }).map {
                try XiphMetadata.parse(readPayload($0, source: source))
            } ?? XiphMetadata.Comment(vendor: Data("SimpleMediaPlayer".utf8), fields: [])
            var comment = XiphMetadata.updating(oldComment, with: draft)
            if draft.editsArtwork {
                comment.fields.removeAll {
                    guard let separator = $0.firstIndex(of: 61),
                          let key = String(data: $0.prefix(upTo: separator), encoding: .ascii)?.uppercased()
                    else { return false }
                    return key == "METADATA_BLOCK_PICTURE" || key == "COVERART" || key == "COVERARTMIME"
                }
            }
            replacements.append((4, try XiphMetadata.encode(comment)))
            if draft.editsArtwork, let artwork = draft.artworkData {
                replacements.append((6, try XiphMetadata.pictureBlock(artwork)))
            }
            var outputBlocks: [(UInt8, Data?, Range<UInt64>?)] = []
            var didWriteComment = false
            for block in blocks {
                if block.type == 4 {
                    if didWriteComment == false {
                        outputBlocks.append((4, replacements[0].1, nil))
                        didWriteComment = true
                    }
                } else if block.type == 6 && draft.editsArtwork {
                    guard block.payload.count >= 4 else { throw MediaMetadataEditError.invalidAudioMetadata }
                    let header = try MediaFileRewriter.read(from: source, at: block.payload.lowerBound, count: 4)
                    if XiphMetadata.pictureType(header) == 3 { continue }
                    outputBlocks.append((block.type, nil, block.payload))
                } else {
                    outputBlocks.append((block.type, nil, block.payload))
                }
            }
            if didWriteComment == false { outputBlocks.append((4, replacements[0].1, nil)) }
            if replacements.count > 1 { outputBlocks.append((6, replacements[1].1, nil)) }
            try output.write(contentsOf: Data("fLaC".utf8))
            for (index, block) in outputBlocks.enumerated() {
                let length = block.1.map { UInt64($0.count) } ?? (block.2!.upperBound - block.2!.lowerBound)
                guard length <= 0xFFFFFF else { throw MediaMetadataEditError.invalidAudioMetadata }
                let last: UInt8 = index == outputBlocks.count - 1 ? 0x80 : 0
                let header = Data([last | block.0, UInt8(length >> 16), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
                try output.write(contentsOf: header)
                if let data = block.1 { try output.write(contentsOf: data) }
                else if let range = block.2 { try MediaFileRewriter.copy(from: source, range: range, to: output) }
            }
            try MediaFileRewriter.copy(from: source, range: blocks.last!.range.upperBound..<size, to: output)
        }
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

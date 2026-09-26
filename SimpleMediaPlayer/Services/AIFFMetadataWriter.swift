import Foundation

enum AIFFMetadataWriter {
    nonisolated private static let supportedFormTypes: Set<Data> = [
        Data("AIFF".utf8),
        Data("AIFC".utf8)
    ]
    nonisolated private static let id3ChunkID = Data("ID3 ".utf8)

    nonisolated static func canWriteMetadata(to url: URL) -> Bool {
        ["aif", "aiff", "aifc"].contains(url.pathExtension.lowercased())
    }

    nonisolated static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        guard canWriteMetadata(to: url) else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }

        try MediaFileRewriter.rewrite(at: url) { source, output, fileSize in
            guard fileSize >= 12 else {
                throw MediaMetadataEditError.invalidAIFFMetadata
            }
            let header = try MediaFileRewriter.read(from: source, at: 0, count: 12)
            guard header.starts(with: Data("FORM".utf8)) else {
                throw MediaMetadataEditError.invalidAIFFMetadata
            }

            let formSize = UInt64(readUInt32(in: header, at: 4))
            let formEnd = 8 + formSize
            guard formSize >= 4, formEnd <= fileSize else {
                throw MediaMetadataEditError.invalidAIFFMetadata
            }

            let formType = Data(header[8..<12])
            guard supportedFormTypes.contains(formType) else {
                throw MediaMetadataEditError.unsupportedAIFFMetadataLayout
            }

            let chunks = try chunks(in: 12..<formEnd, source: source)
            let existingID3Chunk = chunks.first { $0.id == id3ChunkID }
            let existingID3Data = try existingID3Chunk.map {
                try ID3TagWriter.readTagData(
                    from: source,
                    at: $0.contentRange.lowerBound,
                    count: $0.contentRange.upperBound - $0.contentRange.lowerBound
                )
            }
            let updatedID3Data = try ID3TagWriter.updatedTagData(
                for: draft,
                existingTagData: existingID3Data,
                requiresExistingTag: existingID3Data != nil
            )
            let updatedID3Chunk = try makeChunk(id: id3ChunkID, content: updatedID3Data)
            let removedSize = chunks.filter { $0.id == id3ChunkID }.reduce(UInt64(0)) {
                $0 + $1.totalRange.upperBound - $1.totalRange.lowerBound
            }
            let updatedFormSize = formSize - removedSize + UInt64(updatedID3Chunk.count)
            guard updatedFormSize <= UInt32.max else {
                throw MediaMetadataEditError.unsupportedAIFFMetadataLayout
            }

            try output.write(contentsOf: Data("FORM".utf8) + uint32Data(UInt32(updatedFormSize)) + formType)
            var didWriteID3Chunk = false
            for chunk in chunks {
                if chunk.id == id3ChunkID {
                    if didWriteID3Chunk == false {
                        try output.write(contentsOf: updatedID3Chunk)
                        didWriteID3Chunk = true
                    }
                } else {
                    try MediaFileRewriter.copy(from: source, range: chunk.totalRange, to: output)
                }
            }
            if didWriteID3Chunk == false {
                try output.write(contentsOf: updatedID3Chunk)
            }
            try MediaFileRewriter.copy(from: source, range: formEnd..<fileSize, to: output)
        }
    }

    nonisolated private static func chunks(in range: Range<UInt64>, source: FileHandle) throws -> [AIFFChunk] {
        var chunks: [AIFFChunk] = []
        var offset = range.lowerBound

        while offset < range.upperBound {
            guard offset + 8 <= range.upperBound else {
                throw MediaMetadataEditError.invalidAIFFMetadata
            }

            let header = try MediaFileRewriter.read(from: source, at: offset, count: 8)
            let id = Data(header[0..<4])
            let size = UInt64(readUInt32(in: header, at: 4))
            let contentStart = offset + 8
            let contentEnd = contentStart + size
            let totalEnd = contentEnd + (size.isMultiple(of: 2) ? 0 : 1)
            guard contentEnd <= range.upperBound, totalEnd <= range.upperBound else {
                throw MediaMetadataEditError.invalidAIFFMetadata
            }

            chunks.append(AIFFChunk(
                id: id,
                totalRange: offset..<totalEnd,
                contentRange: contentStart..<contentEnd
            ))
            offset = totalEnd
        }

        return chunks
    }

    nonisolated private static func makeChunk(id: Data, content: Data) throws -> Data {
        guard id.count == 4, content.count <= Int(UInt32.max) else {
            throw MediaMetadataEditError.unsupportedAIFFMetadataLayout
        }

        var chunk = Data()
        chunk.append(id)
        chunk.append(uint32Data(UInt32(content.count)))
        chunk.append(content)
        if content.count.isMultiple(of: 2) == false {
            chunk.append(0)
        }
        return chunk
    }

    nonisolated private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    nonisolated private static func uint32Data(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}

nonisolated private struct AIFFChunk: Sendable {
    let id: Data
    let totalRange: Range<UInt64>
    let contentRange: Range<UInt64>
}

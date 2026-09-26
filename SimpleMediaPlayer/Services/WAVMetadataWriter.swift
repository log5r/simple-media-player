import Foundation

nonisolated enum WAVMetadataWriter {
    private struct Chunk {
        let id: Data
        let range: Range<UInt64>
        let content: Range<UInt64>
    }
    private static let id3IDs = [Data("id3 ".utf8), Data("ID3 ".utf8)]
    private static let infoID = Data("LIST".utf8)

    static func canWriteMetadata(to url: URL) -> Bool {
        url.pathExtension.lowercased() == "wav"
    }

    static func read(from url: URL) throws -> AudioTagReadResult {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let size = try source.seekToEnd()
        let chunks = try parse(source, size: size)
        var result = AudioTagReadResult()
        for chunk in chunks where chunk.id == infoID {
            let payload = try read(chunk.content, source: source)
            guard payload.starts(with: Data("INFO".utf8)) else { continue }
            result.values = try infoValues(in: payload)
            break
        }
        if let chunk = chunks.first(where: { id3IDs.contains($0.id) }) {
            let data = try read(chunk.content, source: source)
            if let id3 = try ID3TagWriter.readEmbeddedTag(data) {
                result.values = combine(primary: id3.values, fallback: result.values)
                result.artworkData = id3.artworkData
                result.lyrics = id3.lyrics
            }
        }
        return result
    }

    static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        guard canWriteMetadata(to: url) else { throw MediaMetadataEditError.unsupportedFileFormat }
        try MediaFileRewriter.rewrite(at: url) { source, output, size in
            let chunks = try parse(source, size: size)
            let id3Chunk = chunks.first { id3IDs.contains($0.id) }
            let existingTag = try id3Chunk.map { try ID3TagWriter.readTagData(
                from: source, at: $0.content.lowerBound,
                count: $0.content.upperBound - $0.content.lowerBound
            ) }
            let updatedTag = try ID3TagWriter.updatedTagData(
                for: draft, existingTagData: existingTag, requiresExistingTag: existingTag != nil
            )
            let updatedID3 = try makeChunk(id: Data("id3 ".utf8), payload: updatedTag)
            let updatedINFO = try draft.editsTextMetadata ? makeChunk(id: infoID, payload: infoPayload(draft)) : nil
            var contentsSize: UInt64 = 4
            var didWriteID3 = false
            var didWriteINFO = false
            var pieces: [(Range<UInt64>?, Data?)] = []
            for chunk in chunks {
                let isInfo = try isInfoChunk(chunk, source: source)
                if id3IDs.contains(chunk.id) {
                    if didWriteID3 == false {
                        pieces.append((nil, updatedID3))
                        contentsSize += UInt64(updatedID3.count)
                        didWriteID3 = true
                    }
                } else if draft.editsTextMetadata && isInfo {
                    if didWriteINFO == false, let updatedINFO {
                        pieces.append((nil, updatedINFO))
                        contentsSize += UInt64(updatedINFO.count)
                        didWriteINFO = true
                    }
                } else {
                    pieces.append((chunk.range, nil))
                    contentsSize += chunk.range.upperBound - chunk.range.lowerBound
                }
            }
            if didWriteID3 == false {
                pieces.append((nil, updatedID3))
                contentsSize += UInt64(updatedID3.count)
            }
            if didWriteINFO == false, let updatedINFO {
                pieces.append((nil, updatedINFO))
                contentsSize += UInt64(updatedINFO.count)
            }
            guard contentsSize <= UInt32.max else { throw MediaMetadataEditError.invalidAudioMetadata }
            try output.write(contentsOf: Data("RIFF".utf8) + XiphMetadata.little32(UInt32(contentsSize)) + Data("WAVE".utf8))
            for (range, data) in pieces {
                if let range { try MediaFileRewriter.copy(from: source, range: range, to: output) }
                else if let data { try output.write(contentsOf: data) }
            }
            let originalEnd = 8 + UInt64(XiphMetadata.uint32(try MediaFileRewriter.read(from: source, at: 4, count: 4), at: 0, little: true))
            try MediaFileRewriter.copy(from: source, range: originalEnd..<size, to: output)
        }
    }

    private static func parse(_ source: FileHandle, size: UInt64) throws -> [Chunk] {
        guard size >= 12 else { throw MediaMetadataEditError.invalidAudioMetadata }
        let header = try MediaFileRewriter.read(from: source, at: 0, count: 12)
        guard header.starts(with: Data("RIFF".utf8)), Data(header[8..<12]) == Data("WAVE".utf8) else {
            throw MediaMetadataEditError.invalidAudioMetadata
        }
        let riffEnd = 8 + UInt64(XiphMetadata.uint32(header, at: 4, little: true))
        guard riffEnd >= 12, riffEnd <= size else { throw MediaMetadataEditError.invalidAudioMetadata }
        var chunks: [Chunk] = []
        var cursor: UInt64 = 12
        while cursor < riffEnd {
            guard cursor <= riffEnd - 8 else { throw MediaMetadataEditError.invalidAudioMetadata }
            let chunkHeader = try MediaFileRewriter.read(from: source, at: cursor, count: 8)
            let length = UInt64(XiphMetadata.uint32(chunkHeader, at: 4, little: true))
            guard length <= riffEnd - cursor - 8 else { throw MediaMetadataEditError.invalidAudioMetadata }
            let contentEnd = cursor + 8 + length
            let end = contentEnd + (length % 2)
            guard end <= riffEnd else { throw MediaMetadataEditError.invalidAudioMetadata }
            chunks.append(Chunk(id: Data(chunkHeader[0..<4]), range: cursor..<end, content: (cursor + 8)..<contentEnd))
            cursor = end
        }
        guard chunks.contains(where: { $0.id == Data("fmt ".utf8) }),
              chunks.contains(where: { $0.id == Data("data".utf8) }) else {
            throw MediaMetadataEditError.invalidAudioMetadata
        }
        return chunks
    }

    private static func isInfoChunk(_ chunk: Chunk, source: FileHandle) throws -> Bool {
        guard chunk.id == infoID, chunk.content.upperBound - chunk.content.lowerBound >= 4 else { return false }
        return try MediaFileRewriter.read(from: source, at: chunk.content.lowerBound, count: 4) == Data("INFO".utf8)
    }

    private static func infoPayload(_ draft: MediaMetadataEditDraft) -> Data {
        let fields: [(String, String)] = [
            ("INAM", draft.title), ("IART", draft.artist), ("IPRD", draft.album),
            ("IGNR", draft.genre), ("ICRD", draft.year), ("ITRK", draft.trackNumber),
            ("ICMT", draft.comment)
        ]
        var data = Data("INFO".utf8)
        for (key, value) in fields where value.isEmpty == false {
            data += (try? makeChunk(id: Data(key.utf8), payload: Data(value.utf8) + Data([0]))) ?? Data()
        }
        return data
    }

    private static func infoValues(in data: Data) throws -> MediaMetadataEmbeddedValues {
        var values = MediaMetadataEmbeddedValues()
        var cursor = 4
        while cursor < data.count {
            guard cursor <= data.count - 8 else { throw MediaMetadataEditError.invalidAudioMetadata }
            let length = Int(XiphMetadata.uint32(data, at: cursor + 4, little: true))
            guard length <= data.count - cursor - 8 else { throw MediaMetadataEditError.invalidAudioMetadata }
            let key = String(data: data[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let raw = Data(data[(cursor + 8)..<(cursor + 8 + length)]).prefix(while: { $0 != 0 })
            let value = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1)
            switch key {
            case "INAM": values.title = value
            case "IART": values.artist = value
            case "IPRD": values.album = value
            case "IGNR": values.genre = value
            case "ICRD": values.year = value
            case "ITRK": values.trackNumber = value
            case "ICMT": values.comment = value
            default: break
            }
            cursor += 8 + length + length % 2
        }
        return values
    }

    private static func combine(primary: MediaMetadataEmbeddedValues, fallback: MediaMetadataEmbeddedValues) -> MediaMetadataEmbeddedValues {
        MediaMetadataEmbeddedValues(
            title: primary.title ?? fallback.title, artist: primary.artist ?? fallback.artist,
            album: primary.album ?? fallback.album, genre: primary.genre ?? fallback.genre,
            year: primary.year ?? fallback.year, trackNumber: primary.trackNumber ?? fallback.trackNumber,
            comment: primary.comment ?? fallback.comment, albumArtist: primary.albumArtist ?? fallback.albumArtist,
            composer: primary.composer ?? fallback.composer, discNumber: primary.discNumber ?? fallback.discNumber,
            isCompilation: primary.isCompilation ?? fallback.isCompilation
        )
    }

    private static func makeChunk(id: Data, payload: Data) throws -> Data {
        guard id.count == 4, payload.count <= Int(UInt32.max) else { throw MediaMetadataEditError.invalidAudioMetadata }
        var result = id + XiphMetadata.little32(UInt32(payload.count)) + payload
        if payload.count % 2 != 0 { result.append(0) }
        return result
    }

    private static func read(_ range: Range<UInt64>, source: FileHandle) throws -> Data {
        let length = range.upperBound - range.lowerBound
        guard length <= 64 * 1024 * 1024 else { throw MediaMetadataEditError.invalidAudioMetadata }
        return try MediaFileRewriter.read(from: source, at: range.lowerBound, count: Int(length))
    }
}

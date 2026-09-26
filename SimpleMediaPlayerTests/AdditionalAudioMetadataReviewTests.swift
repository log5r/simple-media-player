import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct AdditionalAudioMetadataReviewTests {
    @Test func wavInfoEditPreservesUnrelatedSubchunks() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: target) }
        var source = try Data(contentsOf: fixture("wav"))
        let copyright = riffChunk("ICOP", payload: Data("Copyright 2026\0".utf8))
        let software = riffChunk("ISFT", payload: Data("Other encoder\0".utf8))
        let oldTitle = riffChunk("INAM", payload: Data("Old title\0".utf8))
        source += riffChunk("LIST", payload: Data("INFO".utf8) + copyright + oldTitle)
        source += riffChunk("LIST", payload: Data("INFO".utf8) + software)
        source.replaceSubrange(4..<8, with: XiphMetadata.little32(UInt32(source.count - 8)))
        try source.write(to: target)

        try WAVMetadataWriter.write(
            MediaMetadataEditDraft(title: "New title", artist: "", album: "", genre: ""), to: target
        )

        let written = try Data(contentsOf: target)
        #expect(written.range(of: copyright) != nil)
        #expect(written.range(of: software) != nil)
        #expect(written.range(of: oldTitle) == nil)
        #expect(try WAVMetadataWriter.read(from: target).values.title == "New title")
    }

    @Test func flacArtworkEditPreservesOtherCommentPictures() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: target) }
        var source = try Data(contentsOf: fixture("flac"))
        let backCover = try XiphMetadata.pictureBlock(Data([1, 2, 3]))
        var backBlock = backCover
        backBlock[3] = 4
        let backField = Data("METADATA_BLOCK_PICTURE=\(backBlock.base64EncodedString())".utf8)
        let frontField = Data("METADATA_BLOCK_PICTURE=\(try XiphMetadata.pictureBlock(Data([4, 5, 6])).base64EncodedString())".utf8)
        var comment = try flacComment(in: source)
        comment.fields += [backField, frontField]
        try replaceFlacComment(in: &source, with: comment)
        try source.write(to: target)

        let newArtwork = Data([7, 8, 9])
        try FLACMetadataWriter.write(
            MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "",
                                   artworkData: newArtwork, editsTextMetadata: false, editsArtwork: true),
            to: target
        )

        let updated = try flacComment(in: Data(contentsOf: target))
        #expect(updated.fields.contains(backField))
        #expect(updated.fields.contains(frontField) == false)
        #expect(try FLACMetadataWriter.read(from: target).artworkData == newArtwork)
    }

    private func fixture(_ ext: String) -> URL {
        if let bundled = Bundle.allBundles.compactMap({ $0.url(forResource: "tag-test", withExtension: ext) }).first {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tag-test.\(ext)")
    }
}

private func riffChunk(_ id: String, payload: Data) -> Data {
    var chunk = Data(id.utf8) + XiphMetadata.little32(UInt32(payload.count)) + payload
    if payload.count % 2 != 0 { chunk.append(0) }
    return chunk
}

private func flacComment(in data: Data) throws -> XiphMetadata.Comment {
    var cursor = 4
    while cursor + 4 <= data.count {
        let header = data[cursor]
        let length = Int(data[cursor + 1]) << 16 | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
        if header & 0x7f == 4 {
            return try XiphMetadata.parse(Data(data[(cursor + 4)..<(cursor + 4 + length)]))
        }
        cursor += 4 + length
        if header & 0x80 != 0 { break }
    }
    throw MediaMetadataEditError.invalidAudioMetadata
}

private func replaceFlacComment(in data: inout Data, with comment: XiphMetadata.Comment) throws {
    var cursor = 4
    while cursor + 4 <= data.count {
        let header = data[cursor]
        let length = Int(data[cursor + 1]) << 16 | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
        if header & 0x7f == 4 {
            let payload = try XiphMetadata.encode(comment)
            let count = payload.count
            guard count <= 0xFFFFFF else { throw MediaMetadataEditError.invalidAudioMetadata }
            data.replaceSubrange(cursor..<(cursor + 4 + length), with: Data([
                header, UInt8(count >> 16), UInt8((count >> 8) & 0xff), UInt8(count & 0xff)
            ]) + payload)
            return
        }
        cursor += 4 + length
        if header & 0x80 != 0 { break }
    }
    throw MediaMetadataEditError.invalidAudioMetadata
}

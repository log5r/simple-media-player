import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct AudioTagStreamingTests {
    @Test func replacingID3v24FooterPreservesAudioAcrossCopyBuffersAndTrailingTag() throws {
        let url = temporaryURL(extension: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let originalTag = Data([0x49, 0x44, 0x33, 4, 0, 0x10, 0, 0, 0, 0])
            + Data([0x33, 0x44, 0x49, 4, 0, 0x10, 0, 0, 0, 0])
        let audio = audioPayload()
        let trailingTag = Data("TAG".utf8) + Data(repeating: 0x31, count: 125)
        try (originalTag + audio + trailingTag).write(to: url)

        try ID3TagWriter.write(draft(title: "Updated title"), to: url)

        let written = try Data(contentsOf: url)
        let tagEnd = id3TagEnd(in: written)
        #expect(written[3] == 4)
        #expect(written[5] & 0x10 == 0)
        #expect(Data(written[tagEnd...]) == audio + trailingTag)
        #expect(try ID3TagWriter.readMetadata(from: url)?.title == "Updated title")

        try ID3TagWriter.write(draft(title: ""), to: url)
        // The emptied tag keeps its size as padding, so only the tag is overwritten.
        let cleared = try Data(contentsOf: url)
        #expect(id3TagEnd(in: cleared) == tagEnd)
        #expect(cleared[10..<tagEnd].allSatisfy { $0 == 0 })
        #expect(Data(cleared[tagEnd...]) == audio + trailingTag)
        #expect(try ID3TagWriter.readMetadata(from: url)?.title == nil)
    }

    @Test func addingID3PreservesAnUntaggedAudioPayloadAcrossCopyBuffers() throws {
        let url = temporaryURL(extension: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = audioPayload()
        try audio.write(to: url)

        try ID3TagWriter.write(draft(title: "New tag"), to: url)

        let written = try Data(contentsOf: url)
        #expect(Data(written[id3TagEnd(in: written)...]) == audio)
        #expect(try ID3TagWriter.readMetadata(from: url)?.title == "New tag")
    }

    @Test(arguments: [
        Data([0x49, 0x44, 0x33, 3, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F]),
        Data([0x49, 0x44, 0x33, 4, 0, 0x10, 0, 0, 0, 0])
    ])
    func rejectsTruncatedID3WithoutChangingTheSource(original: Data) throws {
        let url = temporaryURL(extension: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try original.write(to: url)

        #expect(throws: MediaMetadataEditError.invalidID3Tag) {
            try ID3TagWriter.write(draft(title: "New title"), to: url)
        }

        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: ["AIFF", "AIFC"])
    func rewritingAIFFPreservesLargeAudioOddPaddingAndTrailingBytes(formType: String) throws {
        let url = temporaryURL(extension: formType == "AIFF" ? "aiff" : "aifc")
        defer { try? FileManager.default.removeItem(at: url) }
        let unknownChunk = chunk(id: "JUNK", payload: Data([1, 2, 3]), padding: 0x7F)
        let soundChunk = chunk(id: "SSND", payload: audioPayload())
        let emptyTag = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0])
        let oldTagChunk = chunk(id: "ID3 ", payload: emptyTag)
        let trailingBytes = Data([0xFF, 0xDA, 0x01, 0x30, 0x41])
        let content = Data(formType.utf8) + unknownChunk + oldTagChunk + soundChunk + oldTagChunk
        let original = Data("FORM".utf8) + uint32Data(UInt32(content.count)) + content + trailingBytes
        try original.write(to: url)

        try AIFFMetadataWriter.write(draft(title: "Updated AIFF title"), to: url)

        let written = try Data(contentsOf: url)
        let formEnd = Int(readUInt32(in: written, at: 4)) + 8
        #expect(Data(written[8..<12]) == Data(formType.utf8))
        #expect(Data(written[formEnd...]) == trailingBytes)
        let chunks = try aiffChunks(in: written, formEnd: formEnd)
        try #require(chunks.map(\.id) == ["JUNK", "ID3 ", "SSND"])
        #expect(chunks[0].data == unknownChunk)
        #expect(chunks[2].data == soundChunk)
        let tagChunk = chunks[1].data
        let tagSize = Int(readUInt32(in: tagChunk, at: 4))
        #expect(tagChunk.count == 8 + tagSize + tagSize % 2)
        let tagURL = temporaryURL(extension: "mp3")
        defer { try? FileManager.default.removeItem(at: tagURL) }
        try Data(tagChunk[8..<(8 + tagSize)]).write(to: tagURL)
        #expect(try ID3TagWriter.readMetadata(from: tagURL)?.title == "Updated AIFF title")
    }

    @Test func rejectsAnID3TagThatExtendsBeyondItsAIFFChunk() throws {
        let url = temporaryURL(extension: "aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let truncatedTag = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 20])
        let content = Data("AIFF".utf8) + chunk(id: "ID3 ", payload: truncatedTag)
            + chunk(id: "SSND", payload: Data(repeating: 0, count: 64))
        let original = Data("FORM".utf8) + uint32Data(UInt32(content.count)) + content
        try original.write(to: url)

        #expect(throws: MediaMetadataEditError.invalidID3Tag) {
            try AIFFMetadataWriter.write(draft(title: "New title"), to: url)
        }

        #expect(try Data(contentsOf: url) == original)
    }

    @Test func rejectsAnAIFFChunkWithMissingOddPaddingWithoutChangingTheSource() throws {
        let url = temporaryURL(extension: "aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = Data("AIFFJUNK".utf8) + uint32Data(3) + Data([1, 2, 3])
        let original = Data("FORM".utf8) + uint32Data(UInt32(content.count)) + content
        try original.write(to: url)

        #expect(throws: MediaMetadataEditError.invalidAIFFMetadata) {
            try AIFFMetadataWriter.write(draft(title: "New title"), to: url)
        }

        #expect(try Data(contentsOf: url) == original)
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    private func draft(title: String) -> MediaMetadataEditDraft {
        MediaMetadataEditDraft(title: title, artist: "", album: "", genre: "")
    }

    private func audioPayload() -> Data {
        Data(repeating: 0x91, count: 1_048_579)
            + Data(repeating: 0x62, count: 1_048_573)
            + Data([0xFF, 0xFB, 0x90, 0x64, 0x21])
    }

    private func id3TagEnd(in data: Data) -> Int {
        10 + data[6..<10].reduce(0) { ($0 << 7) | Int($1) }
    }

    private func chunk(id: String, payload: Data, padding: UInt8 = 0) -> Data {
        var data = Data(id.utf8) + uint32Data(UInt32(payload.count)) + payload
        if payload.count.isMultiple(of: 2) == false {
            data.append(padding)
        }
        return data
    }

    private func uint32Data(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func aiffChunks(in data: Data, formEnd: Int) throws -> [(id: String, data: Data)] {
        var offset = 12
        var chunks: [(id: String, data: Data)] = []
        while offset < formEnd {
            try #require(offset + 8 <= formEnd)
            let id = try #require(String(data: data[offset..<(offset + 4)], encoding: .ascii))
            let size = Int(readUInt32(in: data, at: offset + 4))
            let end = offset + 8 + size + size % 2
            try #require(end <= formEnd)
            chunks.append((id, Data(data[offset..<end])))
            offset = end
        }
        return chunks
    }
}

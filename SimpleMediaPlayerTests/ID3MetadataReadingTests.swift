import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct ID3MetadataReadingTests {
    @Test(arguments: [UInt8(2), 3, 4])
    func readsTextMetadataForEachSupportedVersion(version: UInt8) throws {
        let title = String(repeating: "Long title ", count: 18)
        let frames = textFrame(id: version == 2 ? "TT2" : "TIT2", text: title, version: version)
            + textFrame(id: version == 2 ? "TP1" : "TPE1", text: "Artist", version: version)
            + textFrame(id: version == 2 ? "TAL" : "TALB", text: "Album", version: version)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try (tag(version: version, content: frames) + Data([0xFF, 0xFB, 0x90, 0x64])).write(to: url)

        let values = try #require(try ID3TagWriter.readMetadata(from: url))

        #expect(values.title == title.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(values.artist == "Artist")
        #expect(values.album == "Album")
    }

    @Test(arguments: [
        Data(), Data("ID3".utf8), Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0]), Data(repeating: 0xFF, count: 64)
    ])
    func returnsNilForShortOrUntaggedFiles(data: Data) throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        #expect(try ID3TagWriter.readMetadata(from: url) == nil)
    }

    @Test func rejectsInvalidSynchsafeSizeVersionAndFlags() throws {
        let examples: [(Data, MediaMetadataEditError)] = [
            (Data([0x49, 0x44, 0x33, 3, 0, 0, 0x80, 0, 0, 0]), .invalidID3Tag),
            (Data([0x49, 0x44, 0x33, 5, 0, 0, 0, 0, 0, 0]), .unsupportedID3Version(5)),
            (Data([0x49, 0x44, 0x33, 3, 0, 0x80, 0, 0, 0, 0]), .unsupportedID3Flags),
            (Data([0x49, 0x44, 0x33, 2, 0, 0x40, 0, 0, 0, 0]), .unsupportedID3Flags)
        ]
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        for (data, expectedError) in examples {
            try data.write(to: url)

            #expect(throws: expectedError) {
                try ID3TagWriter.readMetadata(from: url)
            }
        }
    }

    @Test(arguments: [UInt8(3), 4])
    func readsFramesAfterExtendedHeader(version: UInt8) throws {
        let extendedHeader = version == 3
            ? integerData(6, byteCount: 4) + Data(repeating: 0, count: 6)
            : synchsafeData(6) + Data([1, 0])
        let content = extendedHeader + textFrame(id: "TIT2", text: "After extended header", version: version)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try (tag(version: version, flags: 0x40, content: content) + Data(repeating: 0xFF, count: 16)).write(to: url)

        #expect(try ID3TagWriter.readMetadata(from: url)?.title == "After extended header")
    }

    @Test func rejectsTagAndFrameSizesBeyondTheirDeclaredBounds() throws {
        let truncatedFrame = Data("TIT2".utf8) + integerData(20, byteCount: 4) + Data([0, 0, 0])
        let examples = [
            Data([0x49, 0x44, 0x33, 3, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F]),
            tag(version: 4, flags: 0x10, content: Data()),
            tag(version: 3, flags: 0x40, content: integerData(20, byteCount: 4)),
            tag(version: 4, flags: 0x40, content: synchsafeData(20)),
            tag(version: 3, content: truncatedFrame) + Data(repeating: 0x61, count: 32)
        ]
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        for data in examples {
            try data.write(to: url)

            #expect(throws: MediaMetadataEditError.invalidID3Tag) {
                try ID3TagWriter.readMetadata(from: url)
            }
        }
    }

    @Test func readsOnlyLeadingTagAndFooterFromLargeSparseFile() throws {
        let content = textFrame(id: "TIT2", text: "Sparse audio", version: 4)
        let headerAndFrames = tag(version: 4, flags: 0x10, content: content)
        let footer = Data([0x33, 0x44, 0x49, 4, 0, 0x10]) + synchsafeData(content.count)
        let tagData = headerAndFrames + footer
        let firstAudioBytes = Data([0xFF, 0xFB, 0x90, 0x64])
        let fileSize: UInt64 = 512 * 1_024 * 1_024
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try (tagData + firstAudioBytes).write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.truncate(atOffset: fileSize)
        try writer.close()

        #expect(try ID3TagWriter.readMetadata(from: url)?.title == "Sparse audio")

        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        #expect(try reader.seekToEnd() == fileSize)
        let readTag = try ID3TagWriter.readTagData(from: reader, at: 0, count: fileSize)
        #expect(readTag == tagData)
        #expect(try reader.offset() == UInt64(tagData.count))
        #expect(try reader.read(upToCount: firstAudioBytes.count) == firstAudioBytes)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
    }

    private func tag(version: UInt8, flags: UInt8 = 0, content: Data) -> Data {
        Data([0x49, 0x44, 0x33, version, 0, flags]) + synchsafeData(content.count) + content
    }

    private func textFrame(id: String, text: String, version: UInt8) -> Data {
        let payload = Data([0]) + Data(text.utf8)
        let size = version == 4
            ? synchsafeData(payload.count)
            : integerData(payload.count, byteCount: version == 2 ? 3 : 4)
        return Data(id.utf8) + size + (version == 2 ? Data() : Data([0, 0])) + payload
    }

    private func synchsafeData(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)
        ])
    }

    private func integerData(_ value: Int, byteCount: Int) -> Data {
        Data((0..<byteCount).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }
}

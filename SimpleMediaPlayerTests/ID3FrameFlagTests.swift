import Foundation
import Testing
@testable import SimpleMediaPlayer

struct ID3FrameFlagReadingTests {
    @Test func readsV24TextWithDataLengthIndicator() throws {
        let content = v24Frame(id: "TIT2", content: textContent("Title with length", encoding: 3), flags: 0x01)
            + v24Frame(id: "TPE1", content: textContent("Artist", encoding: 3))

        let values = try #require(try readMetadata(tag(version: 4, content: content)))

        #expect(values.title == "Title with length")
        #expect(values.artist == "Artist")
    }

    @Test func readsV24UnsynchronisedUTF16Text() throws {
        // "ÿ" is 0xFF 0x00 in UTF-16LE, and the BOM 0xFF 0xFE is unsynchronised as 0xFF 0x00 0xFE.
        let title = "Unsynchronised ÿ title"
        let artist = "Artist ÿ"
        let content = v24Frame(id: "TIT2", content: textContent(title, encoding: 1), flags: 0x02)
            + v24Frame(id: "TPE1", content: textContent(artist, encoding: 1), flags: 0x02)

        let values = try #require(try readMetadata(tag(version: 4, content: content)))

        #expect(values.title == title)
        #expect(values.artist == artist)
    }

    @Test func readsV24TextWithGroupingDataLengthAndUnsynchronisation() throws {
        let title = "Grouped ÿ title"
        let content = v24Frame(id: "TIT2", content: textContent(title, encoding: 1), flags: 0x43)
            + v24Frame(id: "TALB", content: textContent("Album", encoding: 3))

        let values = try #require(try readMetadata(tag(version: 4, content: content)))

        #expect(values.title == title)
        #expect(values.album == "Album")
    }

    /// The group identifier 0xFF followed by the encoding byte 0x00 or the data length indicator is stored
    /// as 0xFF 0x00 0x00, so the additions can be dropped only after reversing unsynchronisation.
    @Test(arguments: [UInt8(0x42), 0x43])
    func readsV24UnsynchronisedFramesWithGroupIdentifierFF(flags: UInt8) throws {
        let title = textContent("Grouped title", encoding: 0)
        let content = v24Frame(id: "TIT2", content: title, flags: flags, groupID: 0xFF)
            + v24Frame(id: "APIC", content: pictureContent(type: 4, image: Data([1, 2, 3])))
            + v24Frame(
                id: "APIC", content: pictureContent(type: 3, image: jpegLikeImage), flags: flags, groupID: 0xFF
            )
            + v24Frame(id: "TALB", content: textContent("Album", encoding: 3))

        let result = try #require(try ID3TagWriter.readEmbeddedTag(tag(version: 4, content: content)))

        #expect(result.values.title == "Grouped title")
        #expect(result.values.album == "Album")
        #expect(result.artworkData == jpegLikeImage)
    }

    @Test func readsV24UnsynchronisedArtworkAndLyrics() throws {
        let lyrics = "First ÿ line\nSecond line"
        let lyricsContent = Data([1]) + Data("eng".utf8) + Data([0xFF, 0xFE, 0, 0])
            + Data([0xFF, 0xFE]) + Data(lyrics.utf16LittleEndianBytes)
        let content = v24Frame(id: "APIC", content: pictureContent(type: 4, image: Data([1, 2, 3])))
            + v24Frame(id: "APIC", content: pictureContent(type: 3, image: jpegLikeImage), flags: 0x03)
            + v24Frame(id: "USLT", content: lyricsContent, flags: 0x03)

        let result = try #require(try ID3TagWriter.readEmbeddedTag(tag(version: 4, content: content)))

        #expect(result.artworkData == jpegLikeImage)
        #expect(result.lyrics == lyrics)
    }

    @Test(arguments: [UInt8(0x09), 0x04])
    func ignoresCompressedOrEncryptedV24Frames(flags: UInt8) throws {
        let hiddenContent = flags & 0x08 != 0 ? compressedTitle : Data("7f3a91c0be5d".utf8)
        let content = v24Frame(id: "TIT2", content: hiddenContent, flags: flags, dataLength: 17)
            + v24Frame(id: "TPE1", content: textContent("Artist", encoding: 3))

        let values = try #require(try readMetadata(tag(version: 4, content: content)))

        #expect(values.title == nil)
        #expect(values.artist == "Artist")
    }

    @Test func readsV23GroupedFrameAndIgnoresCompressedFrame() throws {
        let grouped = v23Frame(id: "TIT2", content: textContent("Grouped v2.3 title", encoding: 0), flags: 0x20)
        let compressed = v23Frame(
            id: "TALB", content: integerData(22, byteCount: 4) + compressedV23Title, flags: 0x80
        )
        let content = grouped + compressed + v23Frame(id: "TPE1", content: textContent("Artist", encoding: 0))

        let values = try #require(try readMetadata(tag(version: 3, content: content)))

        #expect(values.title == "Grouped v2.3 title")
        #expect(values.album == nil)
        #expect(values.artist == "Artist")
    }

    /// Format flag bits outside ID3v2.4 §4.1 %0h00kmnp and ID3v2.3 §3.3.1 %ijk00000 are reserved,
    /// and an unknown extension might change the layout of the frame data.
    @Test(arguments: [(UInt8(4), UInt8(0x10)), (4, 0x80), (3, 0x01), (3, 0x10)])
    func ignoresFramesWithReservedFormatFlags(version: UInt8, flags: UInt8) throws {
        let content = reservedFlagTitleFrame(version: version, flags: flags) + plainArtistFrame(version: version)

        let values = try #require(try readMetadata(tag(version: version, content: content)))

        #expect(values.title == nil)
        #expect(values.artist == "Artist")
    }

    private func readMetadata(_ tagData: Data) throws -> MediaMetadataEmbeddedValues? {
        let file = try TemporaryMP3()
        defer { file.remove() }
        try (tagData + Data([0xFF, 0xFB, 0x90, 0x64])).write(to: file.url)
        return try ID3TagWriter.readMetadata(from: file.url)
    }
}

struct ID3FrameFlagWritingTests {
    @Test func editingTextPreservesUneditedFlaggedFrames() throws {
        let artwork = v24Frame(id: "APIC", content: pictureContent(type: 3, image: jpegLikeImage), flags: 0x03)
        let userText = v24Frame(id: "TXXX", content: compressedTitle, flags: 0x09, dataLength: 17)
        let oldTitle = v24Frame(id: "TIT2", content: textContent("Old title", encoding: 3), flags: 0x01)
        let audio = Data([0xFF, 0xFB, 0x90, 0x64, 0x00, 0xFF, 0x00, 0x11])
        let file = try TemporaryMP3()
        defer { file.remove() }
        try (tag(version: 4, content: oldTitle + artwork + userText) + audio).write(to: file.url)

        try ID3TagWriter.write(
            MediaMetadataEditDraft(title: "New title", artist: "Artist", album: "", genre: ""), to: file.url
        )

        let written = try Data(contentsOf: file.url)
        #expect(written.range(of: artwork) != nil)
        #expect(written.range(of: userText) != nil)
        #expect(written.range(of: oldTitle) == nil)
        let values = try #require(try ID3TagWriter.readMetadata(from: file.url))
        #expect(values.title == "New title")
        #expect(values.artist == "Artist")
        #expect(try ID3TagWriter.readEmbeddedTag(written)?.artworkData == jpegLikeImage)
        #expect(written.suffix(audio.count) == audio)
    }

    @Test func editingLyricsPreservesCompressedTitle() throws {
        let title = v24Frame(id: "TIT2", content: compressedTitle, flags: 0x09, dataLength: 17)
        let file = try TemporaryMP3()
        defer { file.remove() }
        let content = title + v24Frame(id: "TPE1", content: textContent("Artist", encoding: 3))
        try (tag(version: 4, content: content) + Data([0xFF, 0xFB, 0x90, 0x64])).write(to: file.url)

        try ID3TagWriter.write(
            MediaMetadataEditDraft(
                title: "", artist: "", album: "", genre: "", lyrics: "New lyrics",
                editsTextMetadata: false, editsLyrics: true
            ),
            to: file.url
        )

        let written = try Data(contentsOf: file.url)
        #expect(written.range(of: title) != nil)
        let result = try #require(try ID3TagWriter.readEmbeddedTag(written))
        #expect(result.lyrics == "New lyrics")
        #expect(result.values.title == nil)
        #expect(result.values.artist == "Artist")
    }

    @Test(arguments: ["TIT2", "TPE1", "COMM"])
    func refusesToReplaceUnreadableTextFrames(frameID: String) throws {
        let content = v24Frame(id: frameID, content: compressedTitle, flags: 0x09, dataLength: 17)
            + v24Frame(id: "TALB", content: textContent("Album", encoding: 3))
        let original = tag(version: 4, content: content) + Data([0xFF, 0xFB, 0x90, 0x64])
        let file = try TemporaryMP3()
        defer { file.remove() }
        try original.write(to: file.url)

        #expect(throws: MediaMetadataEditError.unsupportedID3Flags) {
            try ID3TagWriter.write(
                MediaMetadataEditDraft(title: "New title", artist: "", album: "Album", genre: ""), to: file.url
            )
        }

        #expect(try Data(contentsOf: file.url) == original)
        #expect(try file.directoryContents() == [file.url.lastPathComponent])
    }

    @Test(arguments: [(UInt8(4), UInt8(0x10)), (4, 0x80), (3, 0x01), (3, 0x10)])
    func refusesToReplaceTitleWithReservedFormatFlags(version: UInt8, flags: UInt8) throws {
        let title = reservedFlagTitleFrame(version: version, flags: flags)
        let original = tag(version: version, content: title + plainArtistFrame(version: version))
            + Data([0xFF, 0xFB, 0x90, 0x64])
        let file = try TemporaryMP3()
        defer { file.remove() }
        try original.write(to: file.url)

        #expect(throws: MediaMetadataEditError.unsupportedID3Flags) {
            try ID3TagWriter.write(
                MediaMetadataEditDraft(title: "New title", artist: "Artist", album: "", genre: ""), to: file.url
            )
        }

        #expect(try Data(contentsOf: file.url) == original)
        #expect(try file.directoryContents() == [file.url.lastPathComponent])
    }

    @Test(arguments: [(UInt8(4), UInt8(0x10)), (4, 0x80), (3, 0x01), (3, 0x10)])
    func editingLyricsPreservesTitleWithReservedFormatFlags(version: UInt8, flags: UInt8) throws {
        let title = reservedFlagTitleFrame(version: version, flags: flags)
        let file = try TemporaryMP3()
        defer { file.remove() }
        let content = title + plainArtistFrame(version: version)
        try (tag(version: version, content: content) + Data([0xFF, 0xFB, 0x90, 0x64])).write(to: file.url)

        try ID3TagWriter.write(
            MediaMetadataEditDraft(
                title: "", artist: "", album: "", genre: "", lyrics: "New lyrics",
                editsTextMetadata: false, editsLyrics: true
            ),
            to: file.url
        )

        let written = try Data(contentsOf: file.url)
        #expect(written.range(of: title) != nil)
        let result = try #require(try ID3TagWriter.readEmbeddedTag(written))
        #expect(result.lyrics == "New lyrics")
        #expect(result.values.title == nil)
        #expect(result.values.artist == "Artist")
    }

    @Test(arguments: [UInt8(0x42), 0x43])
    func replacingArtworkRemovesGroupedUnsynchronisedFrontCover(flags: UInt8) throws {
        let back = v24Frame(id: "APIC", content: pictureContent(type: 4, image: Data([1, 2, 3])), flags: flags)
        let oldFront = v24Frame(
            id: "APIC", content: pictureContent(type: 3, image: jpegLikeImage), flags: flags, groupID: 0xFF
        )
        let original = tag(version: 4, content: back + oldFront)
        let newFront = Data([10, 11, 12])
        let draft = MediaMetadataEditDraft(
            title: "", artist: "", album: "", genre: "", artworkData: newFront,
            editsTextMetadata: false, editsArtwork: true
        )

        let updated = try ID3TagWriter.updatedTagData(for: draft, existingTagData: original)

        #expect(updated.range(of: back) != nil)
        #expect(updated.range(of: oldFront) == nil)
        #expect(try ID3TagWriter.readEmbeddedTag(updated)?.artworkData == newFront)
    }

    @Test func refusesToReplaceArtworkWhenAPictureIsEncrypted() throws {
        let encryptedArtwork = v24Frame(id: "APIC", content: Data("7f3a91c0be5d".utf8), flags: 0x04)
        let content = encryptedArtwork + v24Frame(id: "TIT2", content: textContent("Title", encoding: 3))
        let original = tag(version: 4, content: content) + Data([0xFF, 0xFB, 0x90, 0x64])
        let file = try TemporaryMP3()
        defer { file.remove() }
        try original.write(to: file.url)

        #expect(throws: MediaMetadataEditError.unsupportedID3Flags) {
            try ID3TagWriter.write(
                MediaMetadataEditDraft(
                    title: "", artist: "", album: "", genre: "", artworkData: Data([1, 2, 3]),
                    editsTextMetadata: false, editsArtwork: true
                ),
                to: file.url
            )
        }
        #expect(try Data(contentsOf: file.url) == original)
        #expect(try file.directoryContents() == [file.url.lastPathComponent])

        try ID3TagWriter.write(
            MediaMetadataEditDraft(title: "New title", artist: "", album: "", genre: ""), to: file.url
        )
        #expect(try Data(contentsOf: file.url).range(of: encryptedArtwork) != nil)
        #expect(try ID3TagWriter.readMetadata(from: file.url)?.title == "New title")
    }
}

/// An MP3 file in its own directory, so that tests can confirm that a failed save leaves nothing behind.
private struct TemporaryMP3 {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("audio.mp3")
    }

    func directoryContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// JPEG-like bytes containing 0xFF 0xD8, 0xFF 0xE0, 0xFF 0x00 and 0xFF 0xFF sequences.
private let jpegLikeImage = Data([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0x00, 0x01, 0xFF, 0xFF, 0x7F, 0xFF, 0xD9
])

/// zlib-compressed `"\u{3}Compressed title"` (17 bytes).
private let compressedTitle = Data([
    0x78, 0x9C, 0x63, 0x76, 0xCE, 0xCF, 0x2D, 0x28, 0x4A, 0x2D, 0x2E, 0x4E, 0x4D, 0x51, 0x28, 0xC9, 0x2C, 0xC9,
    0x49, 0x05, 0x00, 0x35, 0xF8, 0x06, 0x5B
])

/// zlib-compressed `"\u{0}Compressed v2.3 title"` (22 bytes).
private let compressedV23Title = Data([
    0x78, 0x9C, 0x63, 0x70, 0xCE, 0xCF, 0x2D, 0x28, 0x4A, 0x2D, 0x2E, 0x4E, 0x4D, 0x51, 0x28, 0x33, 0xD2, 0x33,
    0x56, 0x28, 0xC9, 0x2C, 0xC9, 0x49, 0x05, 0x00, 0x54, 0xC6, 0x07, 0x81
])

private func reservedFlagTitleFrame(version: UInt8, flags: UInt8) -> Data {
    version == 4
        ? v24Frame(id: "TIT2", content: textContent("Reserved flag title", encoding: 3), flags: flags)
        : v23Frame(id: "TIT2", content: textContent("Reserved flag title", encoding: 0), flags: flags)
}

private func plainArtistFrame(version: UInt8) -> Data {
    version == 4
        ? v24Frame(id: "TPE1", content: textContent("Artist", encoding: 3))
        : v23Frame(id: "TPE1", content: textContent("Artist", encoding: 0))
}

private func tag(version: UInt8, content: Data) -> Data {
    Data([0x49, 0x44, 0x33, version, 0, 0]) + synchsafeData(content.count) + content
}

/// Builds an ID3v2.4 frame, adding the group byte, encryption method and data length indicator in flag order.
/// ID3v2.4 §4.1.2: unsynchronisation covers everything after the frame header, so the additions are included.
private func v24Frame(
    id: String, content: Data, flags: UInt8 = 0, dataLength: Int? = nil, groupID: UInt8 = 0x01
) -> Data {
    var additions = Data()
    if flags & 0x40 != 0 { additions.append(groupID) }
    if flags & 0x04 != 0 { additions.append(0x80) }
    if flags & 0x01 != 0 { additions += synchsafeData(dataLength ?? content.count) }
    let body = flags & 0x02 != 0 ? unsynchronised(additions + content) : additions + content
    return Data(id.utf8) + synchsafeData(body.count) + Data([0, flags]) + body
}

/// Builds an ID3v2.3 frame; `content` includes any additions the flags require except the group byte.
private func v23Frame(id: String, content: Data, flags: UInt8 = 0) -> Data {
    let body = (flags & 0x20 != 0 ? Data([0x01]) : Data()) + content
    return Data(id.utf8) + integerData(body.count, byteCount: 4) + Data([0, flags]) + body
}

private func textContent(_ text: String, encoding: UInt8) -> Data {
    switch encoding {
    case 1:
        Data([1, 0xFF, 0xFE]) + Data(text.utf16LittleEndianBytes)
    case 3:
        Data([3]) + Data(text.utf8)
    default:
        Data([encoding]) + (text.data(using: .isoLatin1) ?? Data())
    }
}

private func pictureContent(type: UInt8, image: Data) -> Data {
    Data([0]) + Data("image/jpeg\0".utf8) + Data([type]) + Data("Cover\0".utf8) + image
}

/// ID3v2.4 §6.1: inserts 0x00 after 0xFF when the next byte is 0x00 or %111xxxxx, or when 0xFF is last.
private func unsynchronised(_ data: Data) -> Data {
    let bytes = [UInt8](data)
    var encoded = Data()
    for (index, byte) in bytes.enumerated() {
        encoded.append(byte)
        guard byte == 0xFF else { continue }
        if index + 1 == bytes.count || bytes[index + 1] == 0x00 || bytes[index + 1] >= 0xE0 {
            encoded.append(0x00)
        }
    }
    return encoded
}

private func synchsafeData(_ value: Int) -> Data {
    Data([
        UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)
    ])
}

private func integerData(_ value: Int, byteCount: Int) -> Data {
    Data((0..<byteCount).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
}

private extension String {
    var utf16LittleEndianBytes: [UInt8] {
        utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }
}

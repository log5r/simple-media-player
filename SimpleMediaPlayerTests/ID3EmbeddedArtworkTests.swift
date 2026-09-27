import Foundation
import Testing
@testable import SimpleMediaPlayer

struct ID3EmbeddedArtworkTests {
    @Test(arguments: [UInt8(2), UInt8(3)])
    func prefersFrontCover(version: UInt8) throws {
        let backArtwork = Data([1, 2, 3])
        let frontArtwork = Data([4, 5, 6])
        let withFront = tag(version: version, frames: [
            frame(version: version, type: 4, artwork: backArtwork),
            frame(version: version, type: 3, artwork: frontArtwork)
        ])
        #expect(try ID3TagWriter.readEmbeddedTag(withFront)?.artworkData == frontArtwork)
        #expect(try ID3TagWriter.readEmbeddedTag(
            tag(version: version, frames: [frame(version: version, type: 4, artwork: backArtwork)])
        )?.artworkData == backArtwork)
    }

    @Test(arguments: [UInt8(2), UInt8(3), UInt8(4)])
    func editingFrontCoverPreservesOtherPictures(version: UInt8) throws {
        let back = frame(version: version, type: 4, artwork: Data([1, 2, 3]))
        let artist = frame(version: version, type: 8, artwork: Data([4, 5, 6]))
        let oldFront = frame(version: version, type: 3, artwork: Data([7, 8, 9]))
        let original = tag(version: version, frames: [back, oldFront, artist])
        let newFront = Data([10, 11, 12])
        let replacement = MediaMetadataEditDraft(
            title: "", artist: "", album: "", genre: "", artworkData: newFront,
            editsTextMetadata: false, editsArtwork: true
        )

        let updated = try ID3TagWriter.updatedTagData(for: replacement, existingTagData: original)
        #expect(updated.range(of: back) != nil)
        #expect(updated.range(of: artist) != nil)
        #expect(updated.range(of: oldFront) == nil)
        #expect(try ID3TagWriter.readEmbeddedTag(updated)?.artworkData == newFront)

        let removal = MediaMetadataEditDraft(
            title: "", artist: "", album: "", genre: "", editsTextMetadata: false, editsArtwork: true
        )
        let cleared = try ID3TagWriter.updatedTagData(for: removal, existingTagData: original)
        #expect(cleared.range(of: back) != nil)
        #expect(cleared.range(of: artist) != nil)
        #expect(cleared.range(of: oldFront) == nil)
    }

    @Test func wavArtworkEditPreservesBackCover() throws {
        let fixture = Bundle.allBundles.compactMap { $0.url(forResource: "tag-test", withExtension: "wav") }.first
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/tag-test.wav")
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let back = frame(version: 3, type: 4, artwork: Data([1, 2, 3]))
        let oldFront = frame(version: 3, type: 3, artwork: Data([4, 5, 6]))
        let embeddedTag = tag(version: 3, frames: [back, oldFront])
        var id3Chunk = Data("id3 ".utf8) + XiphMetadata.little32(UInt32(embeddedTag.count)) + embeddedTag
        if embeddedTag.count % 2 != 0 { id3Chunk.append(0) }
        var wav = try Data(contentsOf: fixture)
        wav += id3Chunk
        wav.replaceSubrange(4..<8, with: XiphMetadata.little32(UInt32(wav.count - 8)))
        try wav.write(to: target)

        let newFront = Data([7, 8, 9])
        try WAVMetadataWriter.write(
            MediaMetadataEditDraft(
                title: "", artist: "", album: "", genre: "", artworkData: newFront,
                editsTextMetadata: false, editsArtwork: true
            ),
            to: target
        )

        let updated = try Data(contentsOf: target)
        #expect(updated.range(of: back) != nil)
        #expect(updated.range(of: oldFront) == nil)
        #expect(try WAVMetadataWriter.read(from: target).artworkData == newFront)
    }
}

private func frame(version: UInt8, type: UInt8, artwork: Data) -> Data {
    let frameID = version == 2 ? "PIC" : "APIC"
    let format = version == 2 ? Data("JPG".utf8) : Data("image/jpeg\0".utf8)
    let payload = Data([0]) + format + Data([type, 0]) + artwork
    let size = payload.count
    let header = version == 2
        ? Data([UInt8(size >> 16), UInt8(size >> 8), UInt8(size)])
        : Data([0, 0, 0, UInt8(size), 0, 0])
    return Data(frameID.utf8) + header + payload
}

private func tag(version: UInt8, frames: [Data]) -> Data {
    let content = frames.reduce(into: Data()) { $0 += $1 }
    let header = Data([0x49, 0x44, 0x33, version, 0, 0, 0, 0, 0, UInt8(content.count)])
    return header + content
}

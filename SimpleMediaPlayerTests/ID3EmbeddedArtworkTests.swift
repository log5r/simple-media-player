import Foundation
import Testing
@testable import SimpleMediaPlayer

struct ID3EmbeddedArtworkTests {
    @Test(arguments: [UInt8(2), UInt8(3)])
    func prefersFrontCover(version: UInt8) throws {
        let backArtwork = Data([1, 2, 3])
        let frontArtwork = Data([4, 5, 6])
        let frameID = version == 2 ? "PIC" : "APIC"
        func frame(type: UInt8, artwork: Data) -> Data {
            let format = version == 2 ? Data("JPG".utf8) : Data("image/jpeg\0".utf8)
            let payload = Data([0]) + format + Data([type, 0]) + artwork
            let size = payload.count
            let header = version == 2
                ? Data([UInt8(size >> 16), UInt8(size >> 8), UInt8(size)])
                : Data([0, 0, 0, UInt8(size), 0, 0])
            return Data(frameID.utf8) + header + payload
        }
        func tag(_ frames: [Data]) -> Data {
            let content = frames.reduce(into: Data()) { $0 += $1 }
            let size = content.count
            let header = Data([0x49, 0x44, 0x33, version, 0, 0, 0, 0, 0, UInt8(size)])
            return header + content
        }

        let withFront = tag([
            frame(type: 4, artwork: backArtwork), frame(type: 3, artwork: frontArtwork)
        ])
        #expect(try ID3TagWriter.readEmbeddedTag(withFront)?.artworkData == frontArtwork)
        #expect(try ID3TagWriter.readEmbeddedTag(
            tag([frame(type: 4, artwork: backArtwork)])
        )?.artworkData == backArtwork)
    }
}

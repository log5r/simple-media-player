import Foundation
import Testing
@testable import SimpleMediaPlayer

// Builders and parsers for tags in forms the writers never produce, independent of the writers' own parsing.

/// One frame, item, entry, or field with the bytes it occupies in the file.
nonisolated struct RawTagEntry: Equatable, Sendable {
    let key: String
    let bytes: Data
}

nonisolated extension Array where Element == RawTagEntry {
    func excluding(_ keys: Set<String>) -> [RawTagEntry] { filter { keys.contains($0.key) == false } }
    func including(_ keys: Set<String>) -> [RawTagEntry] { filter { keys.contains($0.key) } }
}

/// Values the item holds, which differ from the file's, and the values a bulk patch writes.
nonisolated enum PatchValues {
    static let artwork = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    static let item = MediaMetadataEditDraft(
        title: "Model title", artist: "Model artist", album: "", genre: "Model genre", year: "1999",
        trackNumber: "1", comment: "Model comment", albumArtist: "", composer: "", discNumber: "",
        isCompilation: false, lyrics: "Model lyrics"
    )
    static let patch = MediaMetadataEditDraft(
        title: "", artist: "", album: "", genre: "", trackNumber: "7/9", comment: "New comment",
        albumArtist: "New album artist"
    )

    static func draft(patching field: MediaMetadataEditField) -> MediaMetadataEditDraft {
        MediaMetadataEditPatch(fields: [field], draft: patch).applying(to: item)
    }

    static func expectWritten(_ field: MediaMetadataEditField, in values: MediaMetadataEmbeddedValues?) {
        switch field {
        case .comment: #expect(values?.comment == "New comment")
        case .trackNumber: #expect(values?.trackNumber == "7/9")
        case .albumArtist: #expect(values?.albumArtist == "New album artist")
        default: Issue.record("No expectation for \(field)")
        }
    }
}

// MARK: - ID3

nonisolated enum TestID3 {
    /// Text frames in ISO-8859-1, which the writers never use, including frames they would normalize away.
    static func frames(version: UInt8) -> [Data] {
        let ids = version == 2
            ? ["TT2", "TP1", "TP1", "TAL", "TYE", "TRK", "TPA", "TP2", "TCM", "TCO", "TCP"]
            : ["TIT2", "TPE1", "TPE1", "TALB", version == 4 ? "TDRC" : "TYER", "TDRC", "TRCK", "TPOS", "TPE2",
               "TCOM", "TCON", "TCMP"]
        let values = ["Old title", "Artist A", "Artist B", "Old album", "2020", "2020-05-01", "3/12", "1/2",
                      "Old album artist", "Old composer", "(13)", "1"]
        var frames = zip(ids, version == 2 ? values.enumerated().filter { $0.offset != 5 }.map(\.element) : values)
            .map { frame($0, Data([0]) + Data($1.utf8), version: version) }
        let language = Data([0]) + Data("eng".utf8) + Data([0])
        frames.append(frame(version == 2 ? "COM" : "COMM", language + Data("Old comment".utf8), version: version))
        frames.append(frame(version == 2 ? "ULT" : "USLT", language + Data("Old lyrics".utf8), version: version))
        let picture = version == 2 ? Data([0]) + Data("PNG".utf8) : Data([0]) + Data("image/png".utf8) + Data([0])
        frames.append(frame(version == 2 ? "PIC" : "APIC", picture + Data([3, 0]) + PatchValues.artwork,
                            version: version))
        if version != 2 { frames.append(frame("TXXX", Data([0]) + Data("KEY\0value".utf8), version: version)) }
        return frames
    }

    static func tag(version: UInt8, frames: [Data]) -> Data {
        let content = frames.reduce(Data(), +)
        return Data("ID3".utf8) + Data([version, 0, 0]) + synchsafe(content.count) + content
    }

    static func frame(_ id: String, _ payload: Data, version: UInt8) -> Data {
        var frame = Data(id.utf8)
        if version == 2 {
            frame += bigEndian(payload.count, byteCount: 3)
        } else {
            frame += (version == 4 ? synchsafe(payload.count) : bigEndian(payload.count, byteCount: 4)) + Data([0, 0])
        }
        return frame + payload
    }

    /// The frames of the tag starting at `start`, keyed by frame ID.
    static func parse(_ data: Data, at start: Int = 0) throws -> [RawTagEntry] {
        let data = Data(data)
        try #require(data[start..<(start + 3)] == Data("ID3".utf8))
        let version = data[start + 3]
        let end = start + 10 + data[(start + 6)..<(start + 10)].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
        let headerSize = version == 2 ? 6 : 10
        var frames: [RawTagEntry] = []
        var offset = start + 10
        while offset + headerSize <= end, data[offset] != 0 {
            let idLength = version == 2 ? 3 : 4
            let sizeBytes = data[(offset + idLength)..<(offset + idLength + (version == 2 ? 3 : 4))]
            let length = version == 4
                ? sizeBytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
                : sizeBytes.reduce(0) { ($0 << 8) | Int($1) }
            try #require(offset + headerSize + length <= end)
            frames.append(RawTagEntry(
                key: String(bytes: data[offset..<(offset + idLength)], encoding: .isoLatin1) ?? "",
                bytes: Data(data[offset..<(offset + headerSize + length)])
            ))
            offset += headerSize + length
        }
        return frames
    }

    static func ids(for field: MediaMetadataEditField, version: UInt8) -> Set<String> {
        switch field {
        case .comment: version == 2 ? ["COM"] : ["COMM"]
        case .trackNumber: version == 2 ? ["TRK"] : ["TRCK"]
        case .albumArtist: version == 2 ? ["TP2"] : ["TPE2"]
        default: []
        }
    }

    static func synchsafe(_ value: Int) -> Data {
        Data([21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) })
    }
}

nonisolated func bigEndian(_ value: Int, byteCount: Int) -> Data {
    Data((0..<byteCount).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}

nonisolated func littleEndian32(_ value: Int) -> Data {
    Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}

// MARK: - RIFF and IFF chunks

nonisolated enum TestChunks {
    static func chunk(_ id: String, _ content: Data, bigEndian isBigEndian: Bool) -> Data {
        let size = isBigEndian ? bigEndian(content.count, byteCount: 4) : littleEndian32(content.count)
        return Data(id.utf8) + size + content + (content.count % 2 == 1 ? Data([0]) : Data())
    }

    /// The chunks after the 12-byte RIFF or FORM header, keyed by chunk ID.
    static func parse(_ data: Data, bigEndian isBigEndian: Bool) throws -> [RawTagEntry] {
        let data = Data(data)
        var chunks: [RawTagEntry] = []
        var offset = 12
        while offset + 8 <= data.count {
            let sizeBytes = data[(offset + 4)..<(offset + 8)]
            let size = isBigEndian
                ? sizeBytes.reduce(0) { ($0 << 8) | Int($1) }
                : sizeBytes.reversed().reduce(0) { ($0 << 8) | Int($1) }
            let end = offset + 8 + size + size % 2
            try #require(end <= data.count)
            chunks.append(RawTagEntry(
                key: String(bytes: data[offset..<(offset + 4)], encoding: .isoLatin1) ?? "",
                bytes: Data(data[offset..<end])
            ))
            offset = end
        }
        return chunks
    }
}

// MARK: - Vorbis comments

nonisolated enum TestXiph {
    /// Fields in forms the writer never produces: two artists, YEAR beside DATE, separate totals, and a spaced key.
    static let fields = [
        "TITLE=Old title", "ARTIST=Artist A", "ARTIST=Artist B", "ALBUM=Old album", "DATE=2020-05-01",
        "YEAR=2020", "TRACKNUMBER=3", "TOTALTRACKS=12", "DISCNUMBER=1", "DISCTOTAL=2",
        "ALBUM ARTIST=Old album artist", "COMPOSER=Old composer", "GENRE=Old genre", "COMPILATION=1",
        "comment=Old comment", "LYRICS=Old lyrics", "CUSTOM=kept"
    ]

    static func entries(_ comment: XiphMetadata.Comment) -> [RawTagEntry] {
        comment.fields.map { field in
            let key = field.firstIndex(of: 61).flatMap { String(bytes: field[..<$0], encoding: .isoLatin1) } ?? ""
            return RawTagEntry(key: key.uppercased(), bytes: field)
        }
    }

    static func keys(for field: MediaMetadataEditField) -> Set<String> {
        switch field {
        case .comment: ["COMMENT"]
        case .trackNumber: ["TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS"]
        default: []
        }
    }

    /// The comment packet of an Ogg Vorbis or Opus stream.
    static func oggComment(in data: Data) throws -> XiphMetadata.Comment {
        let data = Data(data)
        var packets: [Data] = []
        var packet = Data()
        var offset = 0
        while packets.count < 2 {
            try #require(offset + 27 <= data.count && data[offset..<(offset + 4)] == Data("OggS".utf8))
            let laces = data[(offset + 27)..<(offset + 27 + Int(data[offset + 26]))]
            var body = offset + 27 + laces.count
            for lace in laces {
                packet += data[body..<(body + Int(lace))]
                body += Int(lace)
                if lace < 255 {
                    packets.append(packet)
                    packet = Data()
                }
            }
            offset = body
        }
        let header = packets[1].starts(with: Data("OpusTags".utf8)) ? 8 : 7
        return try XiphMetadata.parse(Data(packets[1].dropFirst(header)))
    }
}

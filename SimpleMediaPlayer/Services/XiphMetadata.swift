import Foundation

nonisolated struct AudioTagReadResult: Sendable {
    var values = MediaMetadataEmbeddedValues()
    var artworkData: Data?
    var lyrics: String?
}

nonisolated enum XiphMetadata {
    private static let editedKeys: Set<String> = [
        "TITLE", "ARTIST", "ALBUM", "GENRE", "DATE", "YEAR", "TRACKNUMBER", "COMMENT",
        "ALBUMARTIST", "ALBUM ARTIST", "COMPOSER", "DISCNUMBER", "DISCTOTAL", "TOTALDISCS",
        "TRACKTOTAL", "TOTALTRACKS", "COMPILATION"
    ]
    private static let lyricsKeys: Set<String> = ["LYRICS", "UNSYNCEDLYRICS"]

    struct Comment: Sendable {
        var vendor: Data
        var fields: [Data]
        var trailing = Data()
    }

    static func parse(_ data: Data) throws -> Comment {
        var cursor = 0
        let vendorSize = try takeLength(data, cursor: &cursor)
        let vendor = try take(data, cursor: &cursor, count: vendorSize)
        let fieldCount = try takeLength(data, cursor: &cursor)
        guard fieldCount <= 100_000 else { throw MediaMetadataEditError.invalidAudioMetadata }
        var fields: [Data] = []
        for _ in 0..<fieldCount {
            let size = try takeLength(data, cursor: &cursor)
            fields.append(try take(data, cursor: &cursor, count: size))
        }
        return Comment(vendor: vendor, fields: fields, trailing: Data(data[cursor...]))
    }

    static func encode(_ comment: Comment) throws -> Data {
        guard comment.vendor.count <= Int(UInt32.max), comment.fields.count <= Int(UInt32.max) else {
            throw MediaMetadataEditError.invalidAudioMetadata
        }
        var data = little32(UInt32(comment.vendor.count)) + comment.vendor + little32(UInt32(comment.fields.count))
        for field in comment.fields {
            guard field.count <= Int(UInt32.max) else { throw MediaMetadataEditError.invalidAudioMetadata }
            data += little32(UInt32(field.count)) + field
        }
        return data + comment.trailing
    }

    static func updating(_ comment: Comment, with draft: MediaMetadataEditDraft) -> Comment {
        var result = comment
        result.fields.removeAll { field in
            guard let key = key(in: field) else { return false }
            return (draft.editsTextMetadata && editedKeys.contains(key))
                || (draft.editsArtwork && editablePictureField(field, key: key))
                || (draft.editsLyrics && lyricsKeys.contains(key))
        }
        if draft.editsTextMetadata {
            let values: [(String, String)] = [
                ("TITLE", draft.title), ("ARTIST", draft.artist), ("ALBUM", draft.album),
                ("GENRE", draft.genre), ("DATE", draft.year),
                ("COMMENT", draft.comment), ("ALBUMARTIST", draft.albumArtist),
                ("COMPOSER", draft.composer),
                ("COMPILATION", draft.isCompilation ? "1" : "0")
            ]
            for (key, value) in values where value.isEmpty == false {
                result.fields.append(Data("\(key)=\(value)".utf8))
            }
            appendNumberPair(draft.trackNumber, numberKey: "TRACKNUMBER", totalKey: "TRACKTOTAL", to: &result.fields)
            appendNumberPair(draft.discNumber, numberKey: "DISCNUMBER", totalKey: "DISCTOTAL", to: &result.fields)
        }
        if draft.editsLyrics && draft.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.fields.append(Data("LYRICS=\(draft.lyrics)".utf8))
        }
        return result
    }

    static func read(_ comment: Comment) -> AudioTagReadResult {
        var result = AudioTagReadResult()
        var fields: [String: String] = [:]
        for field in comment.fields {
            guard let separator = field.firstIndex(of: 61),
                  let key = String(data: field.prefix(upTo: separator), encoding: .ascii)?.uppercased(),
                  let value = String(data: field.suffix(from: field.index(after: separator)), encoding: .utf8)
            else { continue }
            if fields[key] == nil { fields[key] = value }
        }
        result.values.title = fields["TITLE"]
        result.values.artist = fields["ARTIST"]
        result.values.album = fields["ALBUM"]
        result.values.genre = fields["GENRE"]
        result.values.year = fields["DATE"] ?? fields["YEAR"]
        result.values.trackNumber = numberPair(
            fields["TRACKNUMBER"], total: fields["TRACKTOTAL"] ?? fields["TOTALTRACKS"]
        )
        result.values.comment = fields["COMMENT"]
        result.values.albumArtist = fields["ALBUMARTIST"] ?? fields["ALBUM ARTIST"]
        result.values.composer = fields["COMPOSER"]
        result.values.discNumber = numberPair(
            fields["DISCNUMBER"], total: fields["DISCTOTAL"] ?? fields["TOTALDISCS"]
        )
        if let compilation = fields["COMPILATION"] {
            result.values.isCompilation = ["1", "true", "yes"].contains(compilation.lowercased())
        }
        result.lyrics = fields["LYRICS"] ?? fields["UNSYNCEDLYRICS"]
        var otherPicture: Data?
        for field in comment.fields {
            guard key(in: field) == "METADATA_BLOCK_PICTURE",
                  let separator = field.firstIndex(of: 61),
                  let encoded = String(data: field.suffix(from: field.index(after: separator)), encoding: .ascii),
                  let picture = Data(base64Encoded: encoded),
                  let artwork = try? pictureData(picture) else { continue }
            if pictureType(picture) == 3 {
                result.artworkData = artwork
                break
            }
            if otherPicture == nil { otherPicture = artwork }
        }
        result.artworkData = result.artworkData ?? otherPicture
            ?? fields["COVERART"].flatMap { Data(base64Encoded: $0) }
        return result
    }

    static func pictureBlock(_ artwork: Data) throws -> Data {
        guard artwork.count <= Int(UInt32.max) else { throw MediaMetadataEditError.invalidArtwork }
        let mime = artwork.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        let mimeData = Data(mime.utf8)
        return big32(3) + big32(UInt32(mimeData.count)) + mimeData + big32(0)
            + big32(0) + big32(0) + big32(0) + big32(0)
            + big32(UInt32(artwork.count)) + artwork
    }

    static func pictureData(_ block: Data) throws -> Data {
        var cursor = 0
        _ = try takeBig32(block, cursor: &cursor)
        _ = try take(block, cursor: &cursor, count: try takeBigLength(block, cursor: &cursor))
        _ = try take(block, cursor: &cursor, count: try takeBigLength(block, cursor: &cursor))
        for _ in 0..<4 { _ = try takeBig32(block, cursor: &cursor) }
        let length = try takeBigLength(block, cursor: &cursor)
        return try take(block, cursor: &cursor, count: length)
    }

    static func pictureType(_ block: Data) -> UInt32? {
        guard block.count >= 4 else { return nil }
        return uint32(block, at: 0, little: false)
    }

    private static func editablePictureField(_ field: Data, key: String) -> Bool {
        if key == "COVERART" || key == "COVERARTMIME" { return true }
        guard key == "METADATA_BLOCK_PICTURE", let separator = field.firstIndex(of: 61),
              let encoded = String(data: field.suffix(from: field.index(after: separator)), encoding: .ascii),
              let block = Data(base64Encoded: encoded) else { return false }
        return pictureType(block) == 3
    }

    private static func key(in field: Data) -> String? {
        guard let separator = field.firstIndex(of: 61) else { return nil }
        return String(data: field.prefix(upTo: separator), encoding: .ascii)?.uppercased()
    }

    private static func appendNumberPair(
        _ value: String, numberKey: String, totalKey: String, to fields: inout [Data]
    ) {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if let first = parts.first, first.isEmpty == false {
            fields.append(Data("\(numberKey)=\(first)".utf8))
        }
        if parts.count == 2, parts[1].isEmpty == false {
            fields.append(Data("\(totalKey)=\(parts[1])".utf8))
        }
    }

    private static func numberPair(_ number: String?, total: String?) -> String? {
        guard let number else { return nil }
        guard number.contains("/") == false, let total, total.isEmpty == false else { return number }
        return "\(number)/\(total)"
    }

    static func little32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) })
    }

    static func big32(_ value: UInt32) -> Data {
        Data((0..<4).reversed().map { UInt8((value >> ($0 * 8)) & 0xff) })
    }

    static func uint32(_ data: Data, at offset: Int, little: Bool) -> UInt32 {
        let values = (0..<4).map { UInt32(data[offset + $0]) }
        return little ? values.enumerated().reduce(0) { $0 | ($1.element << ($1.offset * 8)) }
            : values.reduce(0) { ($0 << 8) | $1 }
    }

    private static func takeLength(_ data: Data, cursor: inout Int) throws -> Int {
        guard cursor <= data.count - 4 else { throw MediaMetadataEditError.invalidAudioMetadata }
        let length = Int(uint32(data, at: cursor, little: true))
        cursor += 4
        return length
    }

    private static func takeBigLength(_ data: Data, cursor: inout Int) throws -> Int {
        Int(try takeBig32(data, cursor: &cursor))
    }

    private static func takeBig32(_ data: Data, cursor: inout Int) throws -> UInt32 {
        guard cursor <= data.count - 4 else { throw MediaMetadataEditError.invalidAudioMetadata }
        let value = uint32(data, at: cursor, little: false)
        cursor += 4
        return value
    }

    private static func take(_ data: Data, cursor: inout Int, count: Int) throws -> Data {
        guard count >= 0, cursor <= data.count, count <= data.count - cursor else {
            throw MediaMetadataEditError.invalidAudioMetadata
        }
        defer { cursor += count }
        return Data(data[cursor..<(cursor + count)])
    }
}

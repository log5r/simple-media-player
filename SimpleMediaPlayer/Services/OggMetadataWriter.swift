import Foundation

nonisolated enum OggMetadataWriter {
    private struct Page {
        let bytes: Data
        let serial: UInt32
        let sequence: UInt32
        let granule: UInt64
        let flags: UInt8
        let segments: [UInt8]
        let end: UInt64
    }
    private struct Prefix {
        let codec: Codec
        let comment: XiphMetadata.Comment
        let packets: [Data]
        let nextOffset: UInt64
        let serial: UInt32
        let nextSequence: UInt32
    }
    private enum Codec { case vorbis, opus }
    private static let maxHeaderSize = 64 * 1024 * 1024

    static func canWriteMetadata(to url: URL) -> Bool {
        guard ["ogg", "oga", "opus"].contains(url.pathExtension.lowercased()) else { return false }
        guard let source = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? source.close() }
        guard let size = try? source.seekToEnd(), size >= 27,
              let page = try? readPage(source, at: 0, size: size),
              page.flags & 2 != 0, page.sequence == 0, page.granule == 0,
              let firstLace = page.segments.first, firstLace < 255 else { return false }
        let body = page.bytes.dropFirst(27 + page.segments.count)
        return body.starts(with: Data([1]) + Data("vorbis".utf8))
            || body.starts(with: Data("OpusHead".utf8))
    }

    static func read(from url: URL) throws -> AudioTagReadResult {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let prefix = try readPrefix(source, size: source.seekToEnd())
        return XiphMetadata.read(prefix.comment)
    }

    static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        guard ["ogg", "oga", "opus"].contains(url.pathExtension.lowercased()) else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }
        try MediaFileRewriter.rewrite(at: url) { source, output, size in
            let prefix = try readPrefix(source, size: size)
            var comment = XiphMetadata.updating(prefix.comment, with: draft)
            if draft.editsArtwork, let artwork = draft.artworkData {
                let picture = try XiphMetadata.pictureBlock(artwork)
                comment.fields.append(Data("METADATA_BLOCK_PICTURE=\(picture.base64EncodedString())".utf8))
            }
            let content = try XiphMetadata.encode(comment)
            var packets = prefix.packets
            switch prefix.codec {
            case .vorbis:
                packets[1] = Data([3]) + Data("vorbis".utf8) + content + Data([1])
            case .opus:
                packets[1] = Data("OpusTags".utf8) + content
            }
            var sequence: UInt32 = 0
            for (packetIndex, packet) in packets.enumerated() {
                let laces = packetLaces(packet.count)
                var laceIndex = 0
                var bodyOffset = 0
                while laceIndex < laces.count {
                    let count = min(255, laces.count - laceIndex)
                    let pageLaces = Array(laces[laceIndex..<(laceIndex + count)])
                    let bodySize = pageLaces.reduce(0) { $0 + Int($1) }
                    let isLastPage = laceIndex + count == laces.count
                    let flags: UInt8 = (packetIndex == 0 && laceIndex == 0 ? 2 : 0)
                        | (laceIndex > 0 ? 1 : 0)
                    let granule: UInt64 = isLastPage ? 0 : UInt64.max
                    let body = Data(packet[bodyOffset..<(bodyOffset + bodySize)])
                    let page = makePage(flags: flags, granule: granule, serial: prefix.serial,
                                        sequence: sequence, laces: pageLaces, body: body)
                    try output.write(contentsOf: page)
                    sequence = sequence &+ 1
                    bodyOffset += bodySize
                    laceIndex += count
                }
            }
            let delta = sequence &- prefix.nextSequence
            var offset = prefix.nextOffset
            var expectedSequence = prefix.nextSequence
            var sawEnd = false
            while offset < size {
                try Task.checkCancellation()
                let page = try readPage(source, at: offset, size: size)
                guard page.serial == prefix.serial, page.sequence == expectedSequence,
                      page.flags & 2 == 0, sawEnd == false else {
                    throw MediaMetadataEditError.invalidAudioMetadata
                }
                var bytes = page.bytes
                writeLittle32(page.sequence &+ delta, to: &bytes, at: 18)
                writeLittle32(0, to: &bytes, at: 22)
                writeLittle32(checksum(bytes), to: &bytes, at: 22)
                try output.write(contentsOf: bytes)
                expectedSequence = expectedSequence &+ 1
                offset = page.end
                sawEnd = page.flags & 4 != 0
            }
            guard sawEnd else { throw MediaMetadataEditError.invalidAudioMetadata }
        }
    }

    private static func readPrefix(_ source: FileHandle, size: UInt64) throws -> Prefix {
        guard size >= 27 else { throw MediaMetadataEditError.invalidAudioMetadata }
        var offset: UInt64 = 0
        var serial: UInt32?
        var expectedSequence: UInt32 = 0
        var packets: [Data] = []
        var partial = Data()
        var completedCommentPage = false
        while offset < size {
            let page = try readPage(source, at: offset, size: size)
            guard page.sequence == expectedSequence,
                  serial == nil || page.serial == serial,
                  page.flags & 4 == 0,
                  page.flags & 1 == (partial.isEmpty ? 0 : 1),
                  page.granule == 0 || page.granule == UInt64.max else {
                throw MediaMetadataEditError.invalidAudioMetadata
            }
            if serial == nil {
                guard page.flags & 2 != 0 else { throw MediaMetadataEditError.invalidAudioMetadata }
                serial = page.serial
            }
            var bodyOffset = 27 + page.segments.count
            for lace in page.segments {
                let length = Int(lace)
                guard partial.count <= maxHeaderSize - length else { throw MediaMetadataEditError.invalidAudioMetadata }
                partial.append(page.bytes[bodyOffset..<(bodyOffset + length)])
                bodyOffset += length
                if lace < 255 {
                    packets.append(partial)
                    partial = Data()
                    if packets.count == 2 { completedCommentPage = true }
                }
            }
            offset = page.end
            expectedSequence = expectedSequence &+ 1
            if completedCommentPage && partial.isEmpty {
                break
            }
        }
        guard packets.count >= 2 else { throw MediaMetadataEditError.invalidAudioMetadata }
        let codec: Codec
        let commentData: Data
        if packets[0].starts(with: Data([1]) + Data("vorbis".utf8)),
           packets[1].starts(with: Data([3]) + Data("vorbis".utf8)),
           packets[1].last == 1 {
            codec = .vorbis
            commentData = Data(packets[1].dropFirst(7).dropLast())
        } else if packets[0].starts(with: Data("OpusHead".utf8)),
                  packets[1].starts(with: Data("OpusTags".utf8)) {
            codec = .opus
            commentData = Data(packets[1].dropFirst(8))
        } else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }
        return Prefix(codec: codec, comment: try XiphMetadata.parse(commentData), packets: packets,
                      nextOffset: offset, serial: serial!, nextSequence: expectedSequence)
    }

    private static func readPage(_ source: FileHandle, at offset: UInt64, size: UInt64) throws -> Page {
        guard offset <= size - 27 else { throw MediaMetadataEditError.invalidAudioMetadata }
        let header = try MediaFileRewriter.read(from: source, at: offset, count: 27)
        guard header.starts(with: Data("OggS".utf8)), header[4] == 0 else {
            throw MediaMetadataEditError.invalidAudioMetadata
        }
        let segmentCount = Int(header[26])
        guard UInt64(segmentCount) <= size - offset - 27 else { throw MediaMetadataEditError.invalidAudioMetadata }
        let segments = try MediaFileRewriter.read(from: source, at: offset + 27, count: segmentCount)
        let bodySize = segments.reduce(0) { $0 + Int($1) }
        let length = 27 + segmentCount + bodySize
        guard UInt64(length) <= size - offset else { throw MediaMetadataEditError.invalidAudioMetadata }
        let bytes = try MediaFileRewriter.read(from: source, at: offset, count: length)
        let storedCRC = XiphMetadata.uint32(bytes, at: 22, little: true)
        var unchecked = bytes
        writeLittle32(0, to: &unchecked, at: 22)
        guard checksum(unchecked) == storedCRC else { throw MediaMetadataEditError.invalidAudioMetadata }
        var granule: UInt64 = 0
        for index in 0..<8 { granule |= UInt64(bytes[6 + index]) << (index * 8) }
        return Page(bytes: bytes, serial: XiphMetadata.uint32(bytes, at: 14, little: true),
                    sequence: XiphMetadata.uint32(bytes, at: 18, little: true), granule: granule,
                    flags: bytes[5], segments: Array(segments), end: offset + UInt64(length))
    }

    private static func packetLaces(_ size: Int) -> [UInt8] {
        var remaining = size
        var laces: [UInt8] = []
        while remaining >= 255 { laces.append(255); remaining -= 255 }
        laces.append(UInt8(remaining))
        return laces
    }

    private static func makePage(flags: UInt8, granule: UInt64, serial: UInt32,
                                 sequence: UInt32, laces: [UInt8], body: Data) -> Data {
        var page = Data("OggS".utf8) + Data([0, flags])
        for index in 0..<8 { page.append(UInt8((granule >> (index * 8)) & 0xff)) }
        page += XiphMetadata.little32(serial) + XiphMetadata.little32(sequence)
        page += Data(repeating: 0, count: 4)
        page.append(UInt8(laces.count))
        page.append(contentsOf: laces)
        page += body
        writeLittle32(checksum(page), to: &page, at: 22)
        return page
    }

    private static func writeLittle32(_ value: UInt32, to data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }
}

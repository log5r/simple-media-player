import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MetadataStreamingTests {
    @Test func failedRewritePreservesOriginalAndRemovesTemporaryFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.mp4")
        let original = Data("original media content".utf8)
        try original.write(to: url)

        #expect(throws: FixtureError.writeFailed) {
            try MediaFileRewriter.rewrite(at: url) { _, output, _ in
                try output.write(contentsOf: Data("partial replacement".utf8))
                throw FixtureError.writeFailed
            }
        }

        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func incompleteCopyCannotReplaceOriginal() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.mp4")
        let original = Data("short source".utf8)
        try original.write(to: url)

        #expect(throws: (any Error).self) {
            try MediaFileRewriter.rewrite(at: url) { source, output, size in
                try MediaFileRewriter.copy(from: source, range: 0..<(size + 1), to: output)
            }
        }

        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func successfulRewritePreservesPermissionsAndBookmarkResolution() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarked.mp4")
        try Data("original".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let replacement = Data("replacement".utf8)

        try MediaFileRewriter.rewrite(at: url) { _, output, _ in
            try output.write(contentsOf: replacement)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale
        )
        #expect(resolved.standardizedFileURL == url.standardizedFileURL)
        #expect(try Data(contentsOf: resolved) == replacement)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test(arguments: [false, true])
    func extendedBoxesPreserveLargePayloadAndCo64Offsets(moovFirst: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("extended.mp4")
        let ftyp = box("ftyp", content: Data("isom".utf8))
        let payload = largePayload()
        let mdat = box("mdat", content: payload, extended: true)
        let placeholderMoov = movie(offset: 0, extended: true)
        let oldOffset = UInt64(ftyp.count + (moovFirst ? placeholderMoov.count : 0) + 16)
        let moov = movie(offset: oldOffset, extended: true)
        let trailingBytes = Data([0xA1, 0xB2, 0xC3])
        let original = ftyp + (moovFirst ? moov + mdat : mdat + moov) + trailingBytes
        try original.write(to: url)

        try MP4MetadataWriter.write(draft(), to: url)

        let written = try Data(contentsOf: url)
        let boxes = try parsedBoxes(in: written, range: 0..<written.count)
        let writtenMdat = try #require(boxes.first(where: { $0.type == "mdat" }))
        #expect(Data(written[writtenMdat.content]) == payload)
        #expect(Data(written[writtenMdat.total]) == mdat)
        #expect(Data(written.prefix(ftyp.count)) == ftyp)
        #expect(written.suffix(trailingBytes.count) == trailingBytes)
        #expect(try chunkOffset(in: written) == UInt64(writtenMdat.content.lowerBound))
        #expect(try MP4TitleReader.title(in: url) == draft().title)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
        if moovFirst {
            #expect(UInt64(writtenMdat.content.lowerBound) > oldOffset)
        } else {
            #expect(UInt64(writtenMdat.content.lowerBound) == oldOffset)
        }
    }

    @Test func zeroSizedMediaBoxPreservesPayloadWhenMovieGrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unbounded.mp4")
        let payload = largePayload()
        let placeholderMoov = movie(offset: 0)
        let moov = movie(offset: UInt64(placeholderMoov.count + 8))
        let mdat = box("mdat", content: payload, toEnd: true)
        try (moov + mdat).write(to: url)

        try MP4MetadataWriter.write(draft(), to: url)

        let written = try Data(contentsOf: url)
        let writtenMdat = try #require(try parsedBoxes(in: written, range: 0..<written.count)
            .first(where: { $0.type == "mdat" }))
        #expect(Data(written[writtenMdat.total]) == mdat)
        #expect(try chunkOffset(in: written) == UInt64(writtenMdat.content.lowerBound))
        #expect(try MP4TitleReader.title(in: url) == draft().title)
    }

    @Test func zeroSizedMovieAfterMediaKeepsChunkOffset() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trailing-movie.mp4")
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let mdat = box("mdat", content: payload)
        var moov = movie(offset: 8)
        moov.replaceSubrange(0..<4, with: Data(repeating: 0, count: 4))
        try (mdat + moov).write(to: url)

        try MP4MetadataWriter.write(draft(), to: url)

        let written = try Data(contentsOf: url)
        #expect(Data(written.prefix(mdat.count)) == mdat)
        #expect(try chunkOffset(in: written) == 8)
        #expect(try MP4TitleReader.title(in: url) == draft().title)
    }

    @Test func movieBetweenMediaBoxesAdjustsOnlyFollowingChunks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("interleaved.mp4")
        let firstMdat = box("mdat", content: Data([1, 2, 3]))
        let secondMdat = box("mdat", content: Data([4, 5, 6, 7]))
        let placeholderMoov = movie(offsets: [0, 0])
        let moov = movie(offsets: [8, UInt64(firstMdat.count + placeholderMoov.count + 8)])
        try (firstMdat + moov + secondMdat).write(to: url)

        try MP4MetadataWriter.write(draft(), to: url)

        let written = try Data(contentsOf: url)
        let mediaBoxes = try parsedBoxes(in: written, range: 0..<written.count).filter { $0.type == "mdat" }
        #expect(mediaBoxes.count == 2)
        #expect(try chunkOffsets(in: written) == mediaBoxes.map { UInt64($0.content.lowerBound) })
        #expect(mediaBoxes.map { Data(written[$0.total]) } == [firstMdat, secondMdat])
    }

    @Test func overflowingChunkOffsetIsRejectedWithoutChangingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("overflow.mp4")
        let original = movie(offset: UInt64.max) + box("mdat", content: Data([1]))
        try original.write(to: url)

        #expect(throws: MediaMetadataEditError.unsupportedMP4MetadataLayout) {
            try MP4MetadataWriter.write(draft(), to: url)
        }

        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func oversizedExtendedBoxIsRejectedWithoutChangingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("invalid.mp4")
        let original = integer(1, bytes: 4) + Data("moov".utf8) + integer(UInt64.max, bytes: 8)
        try original.write(to: url)

        #expect(throws: (any Error).self) {
            try MP4MetadataWriter.write(draft(), to: url)
        }

        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataStreamingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func draft() -> MediaMetadataEditDraft {
        MediaMetadataEditDraft(
            title: "A longer title that grows movie metadata", artist: "Artist", album: "Album", genre: "Genre"
        )
    }

    private func largePayload() -> Data {
        let count = 2 * 1_024 * 1_024 + 257
        let pattern = Data((0..<251).map { UInt8($0) })
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            data.append(pattern.prefix(min(pattern.count, count - data.count)))
        }
        return data
    }

    private func movie(offset: UInt64, extended: Bool = false) -> Data {
        movie(offsets: [offset], extended: extended)
    }

    private func movie(offsets: [UInt64], extended: Bool = false) -> Data {
        var table = integer(0, bytes: 4) + integer(UInt64(offsets.count), bytes: 4)
        for offset in offsets {
            table.append(integer(offset, bytes: 8))
        }
        let co64 = box("co64", content: table)
        let track = box("trak", content: box("mdia", content: box("minf", content: box("stbl", content: co64))))
        return box("moov", content: track, extended: extended)
    }

    private func box(_ type: String, content: Data, extended: Bool = false, toEnd: Bool = false) -> Data {
        let header: Data
        if extended {
            header = integer(1, bytes: 4) + Data(type.utf8) + integer(UInt64(content.count + 16), bytes: 8)
        } else {
            header = integer(toEnd ? 0 : UInt64(content.count + 8), bytes: 4) + Data(type.utf8)
        }
        return header + content
    }

    private func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ((bytes - 1 - $0) * 8)) })
    }

    private func readInteger(in data: Data, at offset: Int, bytes: Int) -> UInt64 {
        data[offset..<(offset + bytes)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func parsedBoxes(in data: Data, range: Range<Int>) throws -> [ParsedBox] {
        var result: [ParsedBox] = []
        var offset = range.lowerBound
        while range.upperBound - offset >= 8 {
            let compactSize = readInteger(in: data, at: offset, bytes: 4)
            let header = compactSize == 1 ? 16 : 8
            guard range.upperBound - offset >= header else { throw FixtureError.invalidBox }
            let size: UInt64
            if compactSize == 1 {
                size = readInteger(in: data, at: offset + 8, bytes: 8)
            } else if compactSize == 0 {
                size = UInt64(range.upperBound - offset)
            } else {
                size = compactSize
            }
            guard size >= UInt64(header), size <= UInt64(range.upperBound - offset) else {
                throw FixtureError.invalidBox
            }
            let end = offset + Int(size)
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(ParsedBox(type: type, total: offset..<end, content: (offset + header)..<end))
            offset = end
        }
        return result
    }

    private func chunkOffset(in data: Data) throws -> UInt64 {
        let offsets = try chunkOffsets(in: data)
        #expect(offsets.count == 1)
        return try #require(offsets.first)
    }

    private func chunkOffsets(in data: Data) throws -> [UInt64] {
        var range = 0..<data.count
        for type in ["moov", "trak", "mdia", "minf", "stbl", "co64"] {
            range = try #require(try parsedBoxes(in: data, range: range).first(where: { $0.type == type })).content
        }
        guard range.count >= 8 else { throw FixtureError.invalidBox }
        let count = readInteger(in: data, at: range.lowerBound + 4, bytes: 4)
        guard count <= UInt64((range.count - 8) / 8) else { throw FixtureError.invalidBox }
        return (0..<Int(count)).map { readInteger(in: data, at: range.lowerBound + 8 + $0 * 8, bytes: 8) }
    }

    private struct ParsedBox {
        let type: String
        let total: Range<Int>
        let content: Range<Int>
    }

    private enum FixtureError: Error, Equatable {
        case writeFailed
        case invalidBox
    }
}

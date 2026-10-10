import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct InPlaceMP4MetadataWriteTests {
    private let chunkOffsetPath = ["moov", "trak", "mdia", "minf", "stbl", "stco"]

    @Test func movieAtEndGrowsAndShrinksInPlace() async throws {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-aac", "m4a"))
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        #expect(try parsedMP4Boxes(in: original).last?.type == "moov")
        let moovStart = try mp4Box(["moov"], in: original).range.lowerBound
        let reference = try await playback(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        try MP4MetadataWriter.write(titleDraft("Title 123456789"), to: fixture.url)

        let grown = try Data(contentsOf: fixture.url)
        #expect(grown.count > original.count)
        #expect(try mp4Box(["moov"], in: grown).range == moovStart..<grown.count)
        #expect(grown.prefix(moovStart) == original.prefix(moovStart))
        #expect(try mp4Box(chunkOffsetPath, in: grown).range.count == mp4Box(chunkOffsetPath, in: original).range.count)
        #expect(try content(chunkOffsetPath, in: grown) == content(chunkOffsetPath, in: original))
        #expect(try await playback(at: fixture.url) == reference)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == "Title 123456789")

        // Two bytes cannot hold a `free` box, so the file ends sooner.
        try MP4MetadataWriter.write(titleDraft("Title 1234567"), to: fixture.url)

        let shrunk = try Data(contentsOf: fixture.url)
        #expect(shrunk.count == grown.count - 2)
        #expect(try mp4Box(["moov"], in: shrunk).range == moovStart..<shrunk.count)
        #expect(shrunk.prefix(moovStart) == original.prefix(moovStart))
        #expect(try await playback(at: fixture.url) == reference)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == "Title 1234567")
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    @Test(arguments: [0, 20])
    func adjacentFreeBoxAbsorbsGrowth(remainder: Int) async throws {
        let fixture = try fixtureWithTrailingBox("free", payload: Data(count: 56))
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.url)
        let moov = try mp4Box(["moov"], in: before)
        let reference = try await playback(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        try MP4MetadataWriter.write(titleDraft("T" + String(repeating: "x", count: 64 - remainder)), to: fixture.url)

        let after = try Data(contentsOf: fixture.url)
        #expect(after.count == before.count)
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)
        #expect(after.prefix(moov.range.lowerBound) == before.prefix(moov.range.lowerBound))
        let boxes = try parsedMP4Boxes(in: after)
        let movieIndex = try #require(boxes.firstIndex { $0.type == "moov" })
        #expect(boxes[movieIndex].range.count == moov.range.count + 64 - remainder)
        #expect(boxes[(movieIndex + 1)...].map(\.type) == (remainder == 0 ? [] : ["free"]))
        #expect(boxes.last?.range.count == (remainder == 0 ? boxes[movieIndex].range.count : remainder))
        #expect(try content(chunkOffsetPath, in: after) == content(chunkOffsetPath, in: before))
        #expect(try await playback(at: fixture.url) == reference)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title?.count == 65 - remainder)
    }

    /// Growth beside large padding writes the movie box and the header of a `free` box over the rest; the old
    /// padding bytes stay, and readers skip them.
    @Test func growthBesideLargePaddingWritesOnlyANewHeader() async throws {
        let fixture = try fixtureWithTrailingBox("skip", payload: Data(repeating: 0xA5, count: 4 * 1_048_576))
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let moov = try mp4Box(["moov"], in: original)
        let reference = try await playback(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        // The second save grows the movie box again into the `free` box the first one wrote.
        for growth in [64, 100] {
            let before = try Data(contentsOf: fixture.url)
            let moovEnd = moov.range.upperBound + growth
            let sizes = try inPlaceWriteSizes {
                try MP4MetadataWriter.write(titleDraft("T" + String(repeating: "x", count: growth)), to: fixture.url)
            }

            let after = try Data(contentsOf: fixture.url)
            #expect(sizes == [moovEnd + 8 - moov.range.lowerBound])
            #expect(after.count == original.count)
            #expect(after.prefix(moov.range.lowerBound) == original.prefix(moov.range.lowerBound))
            #expect(after[(moovEnd + 8)...] == before[(moovEnd + 8)...])
            #expect(after.last == 0xA5)
            let boxes = try parsedMP4Boxes(in: after)
            #expect(boxes.suffix(2).map(\.type) == ["moov", "free"])
            #expect(boxes.last?.range == moovEnd..<after.count)
            let written = try writtenBoxes(at: fixture.url).suffix(2)
            #expect(written.map(\.type) == ["moov", "free"])
            #expect(written.map(\.range)
                == [UInt64(moov.range.lowerBound)..<UInt64(moovEnd), UInt64(moovEnd)..<UInt64(after.count)])
            #expect(try content(chunkOffsetPath, in: after) == content(chunkOffsetPath, in: original))
            #expect(try await playback(at: fixture.url) == reference)
            #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title?.count == growth + 1)
        }
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    /// Padding left beyond 4 GiB takes a `free` header with a 64-bit size. The file is sparse, so it needs
    /// almost no disk space.
    @Test func growthBesidePaddingBeyond4GiBWritesA64BitHeader() async throws {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-aac", "m4a"))
        defer { fixture.remove() }
        try MP4MetadataWriter.write(titleDraft("T"), to: fixture.url)
        let tagged = try Data(contentsOf: fixture.url)
        let moov = try mp4Box(["moov"], in: tagged)
        let paddingSize: UInt64 = (1 << 32) + 4_096
        try (tagged + bigEndian(1, byteCount: 4) + Data("free".utf8) + bigEndian(paddingSize, byteCount: 8))
            .write(to: fixture.url)
        let handle = try FileHandle(forUpdating: fixture.url)
        try handle.truncate(atOffset: UInt64(tagged.count) + paddingSize)
        try handle.close()
        let fileSize = UInt64(tagged.count) + paddingSize
        let reference = try await playback(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        let sizes = try inPlaceWriteSizes {
            try MP4MetadataWriter.write(titleDraft("T" + String(repeating: "x", count: 64)), to: fixture.url)
        }

        let moovEnd = UInt64(moov.range.upperBound + 64)
        #expect(sizes == [Int(moovEnd) + 16 - moov.range.lowerBound])
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try bytes(at: fixture.url, 0..<UInt64(moov.range.lowerBound)) == tagged.prefix(moov.range.lowerBound))
        #expect(try bytes(at: fixture.url, moovEnd..<(moovEnd + 16))
            == bigEndian(1, byteCount: 4) + Data("free".utf8) + bigEndian(fileSize - moovEnd, byteCount: 8))
        let written = try writtenBoxes(at: fixture.url).suffix(2)
        #expect(written.map(\.type) == ["moov", "free"])
        #expect(written.map(\.range) == [UInt64(moov.range.lowerBound)..<moovEnd, moovEnd..<fileSize])
        #expect(try await playback(at: fixture.url) == reference)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title?.count == 65)
    }

    /// Growth that leaves 1–7 bytes, or more than the padding holds, uses the full rewrite.
    @Test(arguments: [3, -100])
    func growthBeyondAdjacentFreeFallsBack(remainder: Int) async throws {
        let fixture = try fixtureWithTrailingBox("free", payload: Data(count: 56))
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.url)
        let reference = try await playback(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        try MP4MetadataWriter.write(titleDraft("T" + String(repeating: "x", count: 64 - remainder)), to: fixture.url)

        let after = try Data(contentsOf: fixture.url)
        #expect(try fixture.fileNumber() != fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)
        #expect(after.count == before.count + 64 - remainder)
        #expect(try content(["mdat"], in: after) == content(["mdat"], in: before))
        #expect(try await playback(at: fixture.url) == reference)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title?.count == 65 - remainder)
    }

    @Test func innerFreeFromShrinkIsReusedForGrowth() async throws {
        let fixture = try fixtureWithTrailingBox("abcd", payload: Data(count: 4))
        defer { fixture.remove() }
        let reference = try await playback(at: fixture.url)
        // Neither at the end nor followed by padding, so growth replaces the file.
        try MP4MetadataWriter.write(titleDraft(String(repeating: "Long ", count: 20)), to: fixture.url)
        let long = try Data(contentsOf: fixture.url)
        let fileNumber = try fixture.fileNumber()

        try MP4MetadataWriter.write(titleDraft("Short"), to: fixture.url)

        let shrunk = try Data(contentsOf: fixture.url)
        #expect(shrunk.count == long.count)
        let moov = try mp4Box(["moov"], in: shrunk)
        let shrunkChildren = try parsedMP4Boxes(in: shrunk, range: moov.contentStart..<moov.range.upperBound)
        #expect(shrunkChildren.last?.type == "free")
        #expect(shrunkChildren.last?.range.count == 94)

        try MP4MetadataWriter.write(titleDraft(String(repeating: "Medium ", count: 8)), to: fixture.url)

        let regrown = try Data(contentsOf: fixture.url)
        #expect(regrown.count == long.count)
        let regrownChildren = try parsedMP4Boxes(in: regrown, range: moov.contentStart..<moov.range.upperBound)
        #expect(regrownChildren.filter { $0.type == "free" }.map(\.range.count) == [44])
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try content(chunkOffsetPath, in: regrown) == content(chunkOffsetPath, in: long))
        #expect(regrown[moov.range.upperBound...] == long[moov.range.upperBound...])
        #expect(try await playback(at: fixture.url) == reference)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == String(repeating: "Medium ", count: 8)
            .trimmingCharacters(in: .whitespaces))
    }

    /// For an unchanged movie box size, the in-place edit writes what the full rewrite writes.
    @Test(arguments: [0, 40])
    func fixedSizeEditMatchesFullRewrite(shrink: Int) throws {
        let fixture = try fixtureWithTrailingBox("abcd", payload: Data(count: 4))
        defer { fixture.remove() }
        try MP4MetadataWriter.write(titleDraft("Title" + String(repeating: "x", count: shrink)), to: fixture.url)
        let replaced = fixture.directory.appendingPathComponent("replaced.m4a")
        try FileManager.default.copyItem(at: fixture.url, to: replaced)
        let fileNumber = try fixture.fileNumber()
        let replacedFileNumber = try fixture.fileNumber(of: replaced)

        try MP4MetadataWriter.write(titleDraft("Other"), to: fixture.url)
        try MediaFileRewriter.$allowsInPlaceEdits.withValue(false) {
            try MP4MetadataWriter.write(titleDraft("Other"), to: replaced)
        }

        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try fixture.fileNumber(of: replaced) != replacedFileNumber)
        #expect(try Data(contentsOf: fixture.url) == Data(contentsOf: replaced))
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == "Other")
    }

    // MARK: - Helpers

    /// The AAC fixture tagged once, followed by a top-level box of `type`.
    private func fixtureWithTrailingBox(_ type: String, payload: Data) throws -> InPlaceFixture {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-aac", "m4a"))
        try MP4MetadataWriter.write(titleDraft("T"), to: fixture.url)
        let data = try Data(contentsOf: fixture.url) + mp4Box(type, payload)
        try data.write(to: fixture.url)
        return fixture
    }

    /// The top-level boxes as the writer parses them, with their types as text.
    private func writtenBoxes(at url: URL) throws -> [(type: String?, range: Range<UInt64>)] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try MP4MetadataWriter.fileBoxes(in: handle, fileSize: handle.seekToEnd()).map {
            (String(bytes: $0.type.data, encoding: .isoLatin1), $0.totalRange)
        }
    }

    private func bytes(at url: URL, _ range: Range<UInt64>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try MediaFileRewriter.read(from: handle, at: range.lowerBound, count: range.count)
    }

    private func bigEndian(_ value: UInt64, byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: value >> ((byteCount - 1 - $0) * 8)) })
    }

    private func content(_ path: [String], in data: Data) throws -> Data {
        let box = try mp4Box(path, in: data)
        return Data(data[box.contentStart..<box.range.upperBound])
    }

    private struct Playback: Equatable {
        let duration: CMTime
        let audioTrackCount: Int
        let samples: [Float]
    }

    private func playback(at url: URL) async throws -> Playback {
        let asset = AVURLAsset(url: url)
        return Playback(
            duration: try await asset.load(.duration),
            audioTrackCount: try await asset.loadTracks(withMediaType: .audio).count,
            samples: try decodedSamples(at: url)
        )
    }
}

import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

/// A full rewrite that changes the size of the metadata region leaves padding, so the next small growth stays in
/// place; one that keeps the size writes the layout it wrote before.
@MainActor
struct RewritePaddingTests {
    private let padding = MediaFileRewriter.rewritePadding
    private let chunkOffsetPath = ["moov", "trak", "mdia", "minf", "stbl", "stco"]

    // MARK: - MP3

    @Test func id3RewriteLeavesPaddingThatTheNextGrowthUses() throws {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-mp3", "mp3"))
        defer { fixture.remove() }
        let audio = try Data(contentsOf: fixture.url)
        let samples = try decodedSamples(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        try InPlaceTestFormat.mp3.write(titleDraft("Title"), to: fixture.url)

        let tagged = try Data(contentsOf: fixture.url)
        let tagSize = try id3TagSize(in: tagged)
        // ID3v2.3 text frames are UTF-16 with a byte order mark.
        let frameEnd = 10 + 10 + 3 + 2 * "Title".utf16.count
        #expect(try fixture.fileNumber() != fileNumber)
        #expect(tagged[0..<6] == Data("ID3".utf8) + Data([3, 0, 0]))
        #expect(tagSize == frameEnd + padding)
        #expect(tagged[frameEnd..<tagSize].allSatisfy { $0 == 0 })
        #expect(tagged[tagSize...] == audio)
        #expect(try InPlaceTestFormat.mp3.title(at: fixture.url) == "Title")
        #expect(try decodedSamples(at: fixture.url) == samples)
        let taggedFileNumber = try fixture.fileNumber()

        let longer = "Title" + String(repeating: "x", count: 200)
        try InPlaceTestFormat.mp3.write(titleDraft(longer), to: fixture.url)

        let grown = try Data(contentsOf: fixture.url)
        let grownFrameEnd = 10 + 10 + 3 + 2 * longer.utf16.count
        #expect(try fixture.fileNumber() == taggedFileNumber)
        #expect(grown.count == tagged.count)
        #expect(try id3TagSize(in: grown) == tagSize)
        #expect(grown[grownFrameEnd..<tagSize].allSatisfy { $0 == 0 })
        #expect(grown[tagSize...] == audio)
        #expect(try InPlaceTestFormat.mp3.title(at: fixture.url) == longer)
        #expect(try decodedSamples(at: fixture.url) == samples)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    /// A rewrite whose tag takes the old tag's size, as for a file that cannot be opened for writing, adds none.
    @Test func id3RewriteOfTheSameSizeAddsNoPadding() throws {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-mp3", "mp3"))
        defer { fixture.remove() }
        let audio = try Data(contentsOf: fixture.url)
        let text = Data([1]) + ("Old title".data(using: .utf16) ?? Data())
        let frame = Data("TIT2".utf8) + bigEndian(UInt64(text.count), byteCount: 4) + Data([0, 0]) + text
        let source = Data("ID3".utf8) + Data([3, 0, 0]) + synchsafe(frame.count) + frame + audio
        try source.write(to: fixture.url)
        let fileNumber = try fixture.fileNumber()

        try MediaFileRewriter.$allowsInPlaceEdits.withValue(false) {
            try InPlaceTestFormat.mp3.write(titleDraft("New title"), to: fixture.url)
        }

        let written = try Data(contentsOf: fixture.url)
        #expect(try fixture.fileNumber() != fileNumber)
        #expect(written.count == source.count)
        #expect(try id3TagSize(in: written) == 10 + frame.count)
        #expect(written[(10 + frame.count)...] == audio)
        #expect(try InPlaceTestFormat.mp3.title(at: fixture.url) == "New title")
    }

    // MARK: - FLAC

    @Test func flacRewriteReplacesPaddingWithOneBlockThatTheNextGrowthUses() throws {
        let fixture = try InPlaceTestFormat.flac.preparedFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let originalEnd = try #require(try flacBlocks(in: original).last).range.upperBound
        let samples = try decodedSamples(at: fixture.url)
        let fileNumber = try fixture.fileNumber()
        // Larger than the fixture's PADDING block.
        let artwork = Data(repeating: 0xAB, count: 20_000)

        try InPlaceTestFormat.flac.write(artworkDraft(artwork), to: fixture.url)

        let rewritten = try Data(contentsOf: fixture.url)
        let blocks = try flacBlocks(in: rewritten)
        let metadataEnd = try #require(blocks.last).range.upperBound
        #expect(try fixture.fileNumber() != fileNumber)
        #expect(blocks.map(\.isLast) == Array(repeating: false, count: blocks.count - 1) + [true])
        #expect(blocks.filter { $0.type == 1 }.map(\.range) == [(metadataEnd - 4 - padding)..<metadataEnd])
        #expect(rewritten[(metadataEnd - padding)..<metadataEnd].allSatisfy { $0 == 0 })
        #expect(rewritten[metadataEnd...] == original[originalEnd...])
        #expect(try AdditionalAudioMetadata.read(from: fixture.url).artworkData == artwork)
        #expect(try decodedSamples(at: fixture.url) == samples)
        let rewrittenFileNumber = try fixture.fileNumber()

        let grownArtwork = Data(repeating: 0xCD, count: 21_000)
        try InPlaceTestFormat.flac.write(artworkDraft(grownArtwork), to: fixture.url)

        let grown = try Data(contentsOf: fixture.url)
        let grownBlocks = try flacBlocks(in: grown)
        #expect(try fixture.fileNumber() == rewrittenFileNumber)
        #expect(grown.count == rewritten.count)
        #expect(grownBlocks.map(\.isLast) == Array(repeating: false, count: grownBlocks.count - 1) + [true])
        #expect(grownBlocks.last?.type == 1)
        #expect(grownBlocks.last?.range == (metadataEnd - 4 - padding + 1_000)..<metadataEnd)
        #expect(grown[metadataEnd...] == original[originalEnd...])
        let read = try AdditionalAudioMetadata.read(from: fixture.url)
        #expect(read.values.title == "Artwork")
        #expect(read.artworkData == grownArtwork)
        #expect(try decodedSamples(at: fixture.url) == samples)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    /// A rewrite whose blocks keep the region's size copies the PADDING block as before.
    @Test func flacRewriteOfTheSameSizeKeepsTheBlocks() throws {
        let fixture = try InPlaceTestFormat.flac.preparedFixture()
        defer { fixture.remove() }
        // The first save adds the fields the next one writes, such as COMPILATION, so their sizes match.
        try InPlaceTestFormat.flac.write(titleDraft("Changed!"), to: fixture.url)
        let original = try Data(contentsOf: fixture.url)
        let originalBlocks = try flacBlocks(in: original)
        let fileNumber = try fixture.fileNumber()

        try MediaFileRewriter.$allowsInPlaceEdits.withValue(false) {
            try InPlaceTestFormat.flac.write(titleDraft("Another!"), to: fixture.url)
        }

        let written = try Data(contentsOf: fixture.url)
        let blocks = try flacBlocks(in: written)
        #expect(try fixture.fileNumber() != fileNumber)
        #expect(written.count == original.count)
        #expect(blocks.map(\.type) == originalBlocks.map(\.type))
        #expect(blocks.map(\.range) == originalBlocks.map(\.range))
        let paddingRange = try #require(originalBlocks.last { $0.type == 1 }).range
        #expect(written[paddingRange] == original[paddingRange])
        #expect(try InPlaceTestFormat.flac.title(at: fixture.url) == "Another!")
    }

    // MARK: - MP4

    @Test func mp4RewriteLeavesAFreeBoxInTheMovieThatTheNextGrowthUses() async throws {
        let fixture = try movieBeforeMediaFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let reference = try await playback(at: fixture.url)
        let fileNumber = try fixture.fileNumber()
        #expect(try parsedMP4Boxes(in: original).map(\.type) == ["ftyp", "free", "moov", "mdat"])

        try MP4MetadataWriter.write(titleDraft("Title"), to: fixture.url)

        let rewritten = try Data(contentsOf: fixture.url)
        let moov = try mp4Box(["moov"], in: rewritten)
        let children = try parsedMP4Boxes(in: rewritten, range: moov.contentStart..<moov.range.upperBound)
        #expect(try fixture.fileNumber() != fileNumber)
        #expect(children.filter { $0.type == "free" }.map(\.range.count) == [padding])
        #expect(children.last?.type == "free")
        #expect(try content(["mdat"], in: rewritten) == content(["mdat"], in: original))
        #expect(try chunkOffsets(in: rewritten) == [mp4Box(["mdat"], in: rewritten).contentStart])
        #expect(try await playback(at: fixture.url) == reference)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == "Title")
        let rewrittenFileNumber = try fixture.fileNumber()

        let longer = "Title" + String(repeating: "x", count: 200)
        try MP4MetadataWriter.write(titleDraft(longer), to: fixture.url)

        let grown = try Data(contentsOf: fixture.url)
        let grownMoov = try mp4Box(["moov"], in: grown)
        let grownChildren = try parsedMP4Boxes(in: grown, range: grownMoov.contentStart..<grownMoov.range.upperBound)
        #expect(try fixture.fileNumber() == rewrittenFileNumber)
        #expect(grown.count == rewritten.count)
        #expect(grownMoov.range == moov.range)
        #expect(grownChildren.filter { $0.type == "free" }.map(\.range.count) == [padding - 200])
        #expect(grown[moov.range.upperBound...] == rewritten[moov.range.upperBound...])
        #expect(try chunkOffsets(in: grown) == chunkOffsets(in: rewritten))
        #expect(try await playback(at: fixture.url) == reference)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == longer)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    /// A movie box at the end of the file is resized in place, so its rewrite needs no padding either.
    @Test func mp4RewriteOfAMovieAtTheEndAddsNoPadding() throws {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-aac", "m4a"))
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let originalMoov = try mp4Box(["moov"], in: original)
        #expect(originalMoov.range.upperBound == original.count)

        try MediaFileRewriter.$allowsInPlaceEdits.withValue(false) {
            try MP4MetadataWriter.write(titleDraft("Title"), to: fixture.url)
        }

        let written = try Data(contentsOf: fixture.url)
        let moov = try mp4Box(["moov"], in: written)
        let children = try parsedMP4Boxes(in: written, range: moov.contentStart..<moov.range.upperBound)
        #expect(moov.range.upperBound == written.count)
        #expect(children.contains { $0.type == "free" } == false)
        #expect(written.prefix(originalMoov.range.lowerBound) == original.prefix(originalMoov.range.lowerBound))
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == "Title")
    }

    /// Fragment offsets cannot move, so a rewrite that keeps the movie box's size writes what the in-place edit
    /// writes, and one that changes it is still refused rather than padded.
    @Test(arguments: [0, 8, 40])
    func fragmentedRewriteKeepsTheLayout(shrink: Int) throws {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-aac", "m4a"))
        defer { fixture.remove() }
        let original = fragmentedMovie(title: "Title" + String(repeating: "x", count: shrink))
        try original.write(to: fixture.url)
        let replaced = fixture.directory.appendingPathComponent("replaced.m4a")
        try original.write(to: replaced)

        try MP4MetadataWriter.write(titleDraft("Other"), to: fixture.url)
        try MediaFileRewriter.$allowsInPlaceEdits.withValue(false) {
            try MP4MetadataWriter.write(titleDraft("Other"), to: replaced)
        }

        let written = try Data(contentsOf: replaced)
        #expect(written == (try Data(contentsOf: fixture.url)))
        #expect(written.count == original.count)
        #expect(try parsedMP4Boxes(in: written).map(\.range) == parsedMP4Boxes(in: original).map(\.range))
        let moofStart = try mp4Box(["moof"], in: original).range.lowerBound
        #expect(written[moofStart...] == original[moofStart...])
        #expect(try MP4MetadataReader.read(from: replaced)?.values.title == "Other")

        let before = try Data(contentsOf: replaced)
        #expect(throws: MediaMetadataEditError.unsupportedMP4MetadataLayout) {
            try MediaFileRewriter.$allowsInPlaceEdits.withValue(false) {
                try MP4MetadataWriter.write(titleDraft("Other" + String(repeating: "x", count: 100)), to: replaced)
            }
        }
        #expect(try Data(contentsOf: replaced) == before)
    }

    // MARK: - Helpers

    private func artworkDraft(_ artwork: Data) -> MediaMetadataEditDraft {
        MediaMetadataEditDraft(
            title: "Artwork", artist: "", album: "", genre: "", artworkData: artwork, editsArtwork: true
        )
    }

    /// The AAC fixture with its movie box moved before the media data, and its chunk offsets moved with it.
    private func movieBeforeMediaFixture() throws -> InPlaceFixture {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-aac", "m4a"))
        let data = try Data(contentsOf: fixture.url)
        let boxes = try parsedMP4Boxes(in: data)
        let moov = try #require(boxes.first { $0.type == "moov" })
        let mdat = try #require(boxes.first { $0.type == "mdat" })
        try #require(moov.range.lowerBound == mdat.range.upperBound && moov.range.upperBound == data.count)
        var movie = Data(data[moov.range])
        let stco = try mp4Box(chunkOffsetPath, in: movie)
        let count = Int(readUInt32(movie, at: stco.contentStart + 4))
        for index in 0..<count {
            let offset = stco.contentStart + 8 + 4 * index
            let moved = readUInt32(movie, at: offset) + UInt32(movie.count)
            movie.replaceSubrange(offset..<(offset + 4), with: bigEndian(UInt64(moved), byteCount: 4))
        }
        try (data[..<mdat.range.lowerBound] + movie + data[mdat.range]).write(to: fixture.url)
        return fixture
    }

    private func fragmentedMovie(title: String) -> Data {
        let data = mp4Box("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(title.utf8))
        // `mp4Box` would encode the copyright sign as UTF-8.
        let item = bigEndian(UInt64(data.count + 8), byteCount: 4) + Data([0xA9, 0x6E, 0x61, 0x6D]) + data
        let meta = mp4Box("meta", Data(count: 4) + mp4Box("ilst", item))
        return mp4Box("moov", mp4Box("udta", meta)) + mp4Box("moof", Data([0, 1, 2, 3]))
            + mp4Box("mdat", Data([4, 5, 6]))
    }

    private func chunkOffsets(in data: Data) throws -> [Int] {
        let stco = try mp4Box(chunkOffsetPath, in: data)
        let count = Int(readUInt32(data, at: stco.contentStart + 4))
        return (0..<count).map { Int(readUInt32(data, at: stco.contentStart + 8 + 4 * $0)) }
    }

    private func content(_ path: [String], in data: Data) throws -> Data {
        let box = try mp4Box(path, in: data)
        return Data(data[box.contentStart..<box.range.upperBound])
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func bigEndian(_ value: UInt64, byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: value >> ((byteCount - 1 - $0) * 8)) })
    }

    private func synchsafe(_ value: Int) -> Data {
        Data((0..<4).map { UInt8((value >> ((3 - $0) * 7)) & 0x7f) })
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

import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct InPlaceTagWriteTests {
    // MARK: - FLAC

    @Test func flacPaddingAbsorbsGrowthAndShrinkLeavesPadding() throws {
        let fixture = try InPlaceTestFormat.flac.preparedFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let metadataEnd = try #require(try flacBlocks(in: original).last).range.upperBound
        let samples = try decodedSamples(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        for artworkSize in [4_000, 0, 6_000] {
            let artwork = artworkSize > 0 ? Data(repeating: 0xAB, count: artworkSize) : nil
            try InPlaceTestFormat.flac.write(artworkDraft(artwork), to: fixture.url)

            let written = try Data(contentsOf: fixture.url)
            #expect(written.count == original.count)
            let blocks = try flacBlocks(in: written)
            #expect(blocks.last?.range.upperBound == metadataEnd)
            #expect(blocks.map(\.isLast) == Array(repeating: false, count: blocks.count - 1) + [true])
            #expect(blocks.last?.type == 1)
            #expect(blocks.filter { $0.type == 1 }.count == 1)
            #expect(written[metadataEnd...] == original[metadataEnd...])
            let read = try AdditionalAudioMetadata.read(from: fixture.url)
            #expect(read.values.title == "Artwork")
            #expect(read.artworkData == artwork)
            #expect(try decodedSamples(at: fixture.url) == samples)
        }
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    /// With `leftover` bytes after the blocks: none fits exactly, 1–3 cannot hold a PADDING header,
    /// and 4 hold an empty one.
    @Test(arguments: [0, 2, 4])
    func flacExactFitAndSmallRemainders(leftover: Int) throws {
        let fixture = try InPlaceTestFormat.flac.preparedFixture()
        defer { fixture.remove() }
        try InPlaceTestFormat.flac.write(artworkDraft(Data(repeating: 0xAB, count: 100)), to: fixture.url)
        let before = try Data(contentsOf: fixture.url)
        let padding = try #require(try flacBlocks(in: before).last)
        #expect(padding.type == 1)
        let metadataEnd = padding.range.upperBound
        let fileNumber = try fixture.fileNumber()
        let artwork = Data(repeating: 0xAB, count: 100 + padding.range.count - leftover)

        try InPlaceTestFormat.flac.write(artworkDraft(artwork), to: fixture.url)

        let after = try Data(contentsOf: fixture.url)
        let blocks = try flacBlocks(in: after)
        #expect(blocks.map(\.isLast) == Array(repeating: false, count: blocks.count - 1) + [true])
        #expect(try AdditionalAudioMetadata.read(from: fixture.url).artworkData == artwork)
        if leftover == 2 {
            #expect(try fixture.fileNumber() != fileNumber)
            #expect(after[blocks.last!.range.upperBound...] == before[metadataEnd...])
        } else {
            #expect(try fixture.fileNumber() == fileNumber)
            #expect(blocks.last?.range.upperBound == metadataEnd)
            #expect(blocks.last?.type == (leftover == 0 ? 6 : 1))
            #expect(blocks.last?.range.count == (leftover == 0 ? artwork.count + 4 + 42 : 4))
            #expect(after[metadataEnd...] == before[metadataEnd...])
        }
        _ = try decodedSamples(at: fixture.url)
    }

    @Test func flacGrowthBeyondPaddingReplacesTheFile() throws {
        let fixture = try InPlaceTestFormat.flac.preparedFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let metadataEnd = try #require(try flacBlocks(in: original).last).range.upperBound
        let samples = try decodedSamples(at: fixture.url)
        let fileNumber = try fixture.fileNumber()
        let artwork = Data(repeating: 0xAB, count: 20_000)

        try InPlaceTestFormat.flac.write(artworkDraft(artwork), to: fixture.url)

        let written = try Data(contentsOf: fixture.url)
        let end = try #require(try flacBlocks(in: written).last).range.upperBound
        #expect(try fixture.fileNumber() != fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)
        #expect(written[end...] == original[metadataEnd...])
        #expect(try AdditionalAudioMetadata.read(from: fixture.url).artworkData == artwork)
        #expect(try decodedSamples(at: fixture.url) == samples)
    }

    // MARK: - ID3

    @Test func id3ShrinkKeepsTagSizeAndLaterGrowthUsesPadding() throws {
        let fixture = try InPlaceTestFormat.mp3.preparedFixture()
        defer { fixture.remove() }
        let tagged = try Data(contentsOf: fixture.url)
        let tagSize = try id3TagSize(in: tagged)
        let samples = try decodedSamples(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        for title in ["Short", String(repeating: "Medium ", count: 10).trimmingCharacters(in: .whitespaces)] {
            try InPlaceTestFormat.mp3.write(titleDraft(title), to: fixture.url)

            let written = try Data(contentsOf: fixture.url)
            #expect(written.count == tagged.count)
            #expect(written[0..<10] == tagged[0..<10])
            #expect(written[tagSize...] == tagged[tagSize...])
            // ID3v2.3 text frames are UTF-16 with a byte order mark.
            let frameEnd = 10 + 10 + 3 + 2 * title.utf16.count
            #expect(written[frameEnd..<tagSize].allSatisfy { $0 == 0 })
            #expect(try InPlaceTestFormat.mp3.title(at: fixture.url) == title)
            #expect(try decodedSamples(at: fixture.url) == samples)
        }
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)

        // Longer than the padding the fixture's rewrite left.
        let longer = String(repeating: "Longer title ", count: 200).trimmingCharacters(in: .whitespaces)
        #expect(10 + 10 + 3 + 2 * longer.utf16.count > tagSize)
        try InPlaceTestFormat.mp3.write(titleDraft(longer), to: fixture.url)

        let grown = try Data(contentsOf: fixture.url)
        #expect(try fixture.fileNumber() != fileNumber)
        // The rewrite moves the audio anyway, so it leaves padding after the frames.
        let grownFrameEnd = 10 + 10 + 3 + 2 * longer.utf16.count
        #expect(try id3TagSize(in: grown) == grownFrameEnd + MediaFileRewriter.rewritePadding)
        #expect(grown[grownFrameEnd..<(try id3TagSize(in: grown))].allSatisfy { $0 == 0 })
        #expect(grown[try id3TagSize(in: grown)...] == tagged[tagSize...])
        #expect(try InPlaceTestFormat.mp3.title(at: fixture.url) == longer)
        #expect(try decodedSamples(at: fixture.url) == samples)
    }

    @Test func id3v24FooterSpaceBecomesPadding() throws {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-mp3", "mp3"))
        defer { fixture.remove() }
        let audio = try Data(contentsOf: fixture.url)
        let text = Data([3]) + Data("An original title".utf8)
        let frame = Data("TIT2".utf8) + synchsafe(text.count) + Data([0, 0]) + text
        let source = Data("ID3".utf8) + Data([4, 0, 0x10]) + synchsafe(frame.count) + frame
            + Data("3DI".utf8) + Data([4, 0, 0x10]) + synchsafe(frame.count) + audio
        try source.write(to: fixture.url)
        let samples = try decodedSamples(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        let sizes = try inPlaceWriteSizes { try InPlaceTestFormat.mp3.write(titleDraft("Short"), to: fixture.url) }

        let written = try Data(contentsOf: fixture.url)
        // A footer leaves no padding, so the whole tag is written.
        #expect(sizes == [20 + frame.count])
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(written.count == source.count)
        // No footer flag, and the size covers the old footer as padding.
        #expect(written[0..<6] == Data("ID3".utf8) + Data([4, 0, 0]))
        #expect(written[6..<10] == synchsafe(frame.count + 10))
        #expect(try id3TagSize(in: written) == 20 + frame.count)
        #expect(written[(20 + 1 + 5)..<(20 + frame.count)].allSatisfy { $0 == 0 })
        #expect(written[(20 + frame.count)...] == audio)
        #expect(try InPlaceTestFormat.mp3.title(at: fixture.url) == "Short")
        #expect(try decodedSamples(at: fixture.url) == samples)
    }

    /// Beside large padding, only the range up to the end of the old or the new frames, whichever is later, is
    /// written; the padding after it is already zero.
    @Test(arguments: ["Short", String(repeating: "Longer title ", count: 12).trimmingCharacters(in: .whitespaces)])
    func id3EditBesideLargePaddingWritesOnlyTheFrames(title: String) throws {
        let fixture = try InPlaceTestFormat.mp3.preparedFixture()
        defer { fixture.remove() }
        let tagged = try Data(contentsOf: fixture.url)
        let framesEnd = try id3TagSize(in: tagged)
        let paddingSize = 4 * 1_048_576
        let tagSize = framesEnd + paddingSize
        let source = tagged.prefix(6) + synchsafe(tagSize - 10) + tagged[10..<framesEnd] + Data(count: paddingSize)
            + tagged[framesEnd...]
        try source.write(to: fixture.url)
        let samples = try decodedSamples(at: fixture.url)
        let fileNumber = try fixture.fileNumber()

        let sizes = try inPlaceWriteSizes { try InPlaceTestFormat.mp3.write(titleDraft(title), to: fixture.url) }

        let written = try Data(contentsOf: fixture.url)
        let newFramesEnd = 10 + 10 + 3 + 2 * title.utf16.count
        let oldContentEnd = try #require(source[10..<framesEnd].lastIndex { $0 != 0 }) + 1
        // The short title leaves old frame bytes to clear; the long one ends after them.
        #expect(sizes == [max(newFramesEnd, oldContentEnd)])
        #expect((newFramesEnd < oldContentEnd) == (title == "Short"))
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(written.count == source.count)
        #expect(written[0..<10] == source[0..<10])
        #expect(written[newFramesEnd..<tagSize].allSatisfy { $0 == 0 })
        #expect(written[tagSize...] == source[tagSize...])
        #expect(try InPlaceTestFormat.mp3.title(at: fixture.url) == title)
        #expect(try decodedSamples(at: fixture.url) == samples)
    }

    // MARK: - Failure and cancellation

    @Test(arguments: InPlaceTestFormat.allCases, [false, true])
    func writeErrorRestoresTheOriginalBytes(format: InPlaceTestFormat, completesWrite: Bool) throws {
        let fixture = try format.preparedFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let fileNumber = try fixture.fileNumber()
        let analysisEntry = try #require(MusicAnalysisCache.entryURL(for: fixture.url, in: fixture.directory))
        // MP4 grows at the end of the file, so a complete write also extends it.
        let draft = format == .mp4 ? titleDraft(String(repeating: "Grown ", count: 20)) : titleDraft("Short")

        #expect(throws: InjectedWriteError.self) {
            try MediaFileRewriter.$inPlaceWrite.withValue({ handle, data in
                try handle.write(contentsOf: completesWrite ? data : data.prefix(data.count / 2))
                throw InjectedWriteError()
            }, operation: {
                try format.write(draft, to: fixture.url)
            })
        }

        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)
        // The restored modification date keeps the analysis cache key.
        #expect(MusicAnalysisCache.entryURL(for: fixture.url, in: fixture.directory) == analysisEntry)
    }

    @Test(arguments: InPlaceTestFormat.allCases)
    func cancellationBeforeWritingLeavesTheFileUnchanged(format: InPlaceTestFormat) async throws {
        let fixture = try format.preparedFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let fileNumber = try fixture.fileNumber()
        let url = fixture.url

        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try format.write(titleDraft("Short"), to: url)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(try fixture.fileNumber() == fileNumber)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    @Test func inPlaceEditCarriesOverTheAnalysisCacheEntry() throws {
        let fixture = try InPlaceTestFormat.flac.preparedFixture()
        defer { fixture.remove() }
        let cacheDirectory = fixture.directory.appendingPathComponent("cache", isDirectory: true)
        let entry = try #require(MusicAnalysisCache.entryURL(for: fixture.url, in: cacheDirectory))
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: entry)
        let replacement = Data("fLaC".utf8)

        try MediaFileRewriter.update(at: fixture.url, analysisCacheDirectory: cacheDirectory) { _, _ in
            MediaFileRewriter.InPlaceEdit(offset: 0, originalLength: 4, data: replacement)
        } rewrite: { _, _, _ in
            Issue.record("The edit fits in place")
        }

        let carried = try #require(MusicAnalysisCache.entryURL(for: fixture.url, in: cacheDirectory))
        #expect(try Data(contentsOf: carried) == Data("cached".utf8))
    }

    // MARK: - Helpers

    private func artworkDraft(_ artwork: Data?) -> MediaMetadataEditDraft {
        MediaMetadataEditDraft(
            title: "Artwork", artist: "", album: "", genre: "", artworkData: artwork, editsArtwork: true
        )
    }

    private func synchsafe(_ value: Int) -> Data {
        Data((0..<4).map { UInt8((value >> ((3 - $0) * 7)) & 0x7f) })
    }
}

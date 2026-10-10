import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct OggMetadataWriteTests {
    enum Corruption: String, CaseIterable, Sendable {
        case checksum, sequenceGap, foreignSerial, beginningOfStream
        case truncatedBody, truncatedHeader, missingEndOfStream, pageAfterEndOfStream, bytesAfterEndOfStream
    }

    private struct OggPage {
        let range: Range<Int>
        let flags: UInt8
        let serial: UInt32
        let sequence: UInt32
        let storedCRC: UInt32
        let segments: [UInt8]
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private let shortDraft = MediaMetadataEditDraft(title: "Short", artist: "", album: "", genre: "")
    private let growingDraft = MediaMetadataEditDraft(
        title: "Large comment", artist: "", album: "", genre: "",
        artworkData: Data(repeating: 0xAB, count: 80_000), editsArtwork: true
    )

    @Test func tableChecksumMatchesBitwiseReference() throws {
        var generator = SplitMix64(state: 1)
        var inputs = [Data(), Data([0]), Data([0xff]), Data("123456789".utf8)]
        for count in [2, 3, 5, 6, 7, 9, 13, 255, 1_000, 4_099] {
            inputs.append(randomData(count, using: &generator))
        }
        for fileExtension in ["ogg", "opus"] {
            let data = try Data(contentsOf: fixture(fileExtension))
            inputs += try pages(in: data).map { zeroingCRC(data[$0.range]) }
        }

        for input in inputs {
            #expect(OggMetadataWriter.checksum(input) == referenceChecksum(input), "\(input.count) bytes")
        }
        // CRC-32/POSIX differs from Ogg's CRC only by its final XOR.
        #expect(OggMetadataWriter.checksum(Data("123456789".utf8)) == 0x765E_7680 ^ 0xFFFF_FFFF)
    }

    @Test(arguments: ["ogg", "opus"])
    func fixturePageChecksumsValidate(fileExtension: String) throws {
        let data = try Data(contentsOf: fixture(fileExtension))
        let pages = try pages(in: data)
        #expect(pages.count >= 3)
        for page in pages {
            #expect(referenceChecksum(zeroingCRC(data[page.range])) == page.storedCRC)
            #expect(Data(data[page.range]).withUnsafeBytes(OggMetadataWriter.pageChecksum) == page.storedCRC)
        }
    }

    @Test(arguments: ["ogg", "opus"], [false, true])
    func sameHeaderPageCountKeepsAudioPagesByteIdentical(fileExtension: String, synthetic: Bool) throws {
        let source = synthetic
            ? try syntheticStream(fileExtension, audioPageCount: 12)
            : try Data(contentsOf: fixture(fileExtension))
        // libvorbis shares a page between the comment and setup headers, while the writer gives each
        // header packet its own pages; a file the writer has already saved keeps its page count.
        let original = try writing(
            MediaMetadataEditDraft(title: "Saved", artist: "", album: "", genre: ""), to: source, fileExtension,
            chunkSize: MediaFileRewriter.copyBufferSize
        )
        let target = try temporaryFile(original, fileExtension)
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        try OggMetadataWriter.write(shortDraft, to: target)

        let written = try Data(contentsOf: target)
        let originalPages = try pages(in: original)
        let writtenPages = try pages(in: written)
        #expect(writtenPages.count == originalPages.count)
        let audioStart = originalPages.count - (try audioPageCount(in: source))
        #expect(written[writtenPages[audioStart].range.lowerBound...]
            == original[originalPages[audioStart].range.lowerBound...])
        #expect(try AdditionalAudioMetadata.read(from: target).values.title == shortDraft.title)
    }

    @Test(arguments: ["ogg", "opus"])
    func growingCommentRenumbersAudioPagesWithValidChecksums(fileExtension: String) throws {
        let original = try syntheticStream(fileExtension, audioPageCount: 12)
        let target = try temporaryFile(original, fileExtension)
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        try OggMetadataWriter.write(growingDraft, to: target)

        let written = try Data(contentsOf: target)
        let originalPages = try pages(in: original)
        let writtenPages = try pages(in: written)
        let originalHeaderCount = headerPageCount(originalPages)
        let headerCount = writtenPages.count - (originalPages.count - originalHeaderCount)
        #expect(headerCount > originalHeaderCount)
        #expect(writtenPages.map(\.sequence) == Array(0..<UInt32(writtenPages.count)))
        #expect(Set(writtenPages.map(\.serial)) == [originalPages[0].serial])
        #expect(writtenPages.map { $0.flags & 6 } == [2] + Array(repeating: 0, count: writtenPages.count - 2) + [4])
        for page in writtenPages {
            #expect(referenceChecksum(zeroingCRC(written[page.range])) == page.storedCRC)
        }
        let originalAudio = originalPages[originalHeaderCount...].map { maskingSequenceAndCRC(original[$0.range]) }
        let writtenAudio = writtenPages[headerCount...].map { maskingSequenceAndCRC(written[$0.range]) }
        #expect(writtenAudio == originalAudio)
        let read = try AdditionalAudioMetadata.read(from: target)
        #expect(read.values.title == growingDraft.title)
        #expect(read.artworkData == growingDraft.artworkData)
    }

    @Test(arguments: ["ogg", "opus"], [1, 7, 100, 4_093])
    func smallChunksProduceTheSameOutput(fileExtension: String, chunkSize: Int) throws {
        var streams = [try Data(contentsOf: fixture(fileExtension))]
        if chunkSize > 1 {
            streams.append(try syntheticStream(fileExtension, audioPageCount: chunkSize < 100 ? 4 : 24))
        }
        for original in streams {
            for draft in [shortDraft, growingDraft] {
                let expected = try writing(
                    draft, to: original, fileExtension, chunkSize: MediaFileRewriter.copyBufferSize
                )
                let actual = try writing(draft, to: original, fileExtension, chunkSize: chunkSize)
                #expect(actual == expected)
                #expect(actual != original)
            }
        }
    }

    @Test(arguments: Corruption.allCases, [100, MediaFileRewriter.copyBufferSize])
    func corruptAudioPageLeavesSourceUnchanged(corruption: Corruption, chunkSize: Int) throws {
        let corrupted = try corrupting(syntheticStream("opus", audioPageCount: 6), with: corruption)
        let target = try temporaryFile(corrupted, "opus")
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        #expect(OggMetadataWriter.canWriteMetadata(to: target))

        for draft in [shortDraft, growingDraft] {
            #expect(throws: MediaMetadataEditError.invalidAudioMetadata) {
                try OggMetadataWriter.write(draft, to: target, chunkSize: chunkSize)
            }
            #expect(try Data(contentsOf: target) == corrupted)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".metadata-") }
        #expect(leftovers.isEmpty)
    }

}

// MARK: - Ogg helpers independent of the writer

extension OggMetadataWriteTests {
    private func referenceChecksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }

    private func pages(in data: Data) throws -> [OggPage] {
        var pages: [OggPage] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.endIndex - offset >= 27, data[offset..<(offset + 4)].elementsEqual("OggS".utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let segmentCount = Int(data[offset + 26])
            let segments = [UInt8](data[(offset + 27)..<(offset + 27 + segmentCount)])
            let end = offset + 27 + segmentCount + segments.reduce(0) { $0 + Int($1) }
            guard end <= data.endIndex else { throw CocoaError(.fileReadCorruptFile) }
            pages.append(OggPage(
                range: offset..<end, flags: data[offset + 5],
                serial: little32(data, at: offset + 14), sequence: little32(data, at: offset + 18),
                storedCRC: little32(data, at: offset + 22), segments: segments
            ))
            offset = end
        }
        return pages
    }

    /// Pages up to the one that completes the comment packet, as the writer reads them.
    private func headerPageCount(_ pages: [OggPage]) -> Int {
        var packets = 0
        for (index, page) in pages.enumerated() {
            packets += page.segments.filter { $0 < 255 }.count
            if packets >= 2, let last = page.segments.last, last < 255 { return index + 1 }
        }
        return pages.count
    }

    private func audioPageCount(in data: Data) throws -> Int {
        let pages = try pages(in: data)
        return pages.count - headerPageCount(pages)
    }

    private func syntheticStream(_ fileExtension: String, audioPageCount: Int) throws -> Data {
        let original = try Data(contentsOf: fixture(fileExtension))
        let originalPages = try pages(in: original)
        let headerCount = headerPageCount(originalPages)
        var stream = Data(original[..<originalPages[headerCount - 1].range.upperBound])
        var generator = SplitMix64(state: UInt64(audioPageCount))
        for index in 0..<audioPageCount {
            var laces = (0..<[1, 17, 255][index % 3]).map { _ in UInt8.random(in: 1...255, using: &generator) }
            laces[laces.count - 1] = min(laces[laces.count - 1], 254)
            let body = randomData(laces.reduce(0) { $0 + Int($1) }, using: &generator)
            stream += makePage(
                flags: index == audioPageCount - 1 ? 4 : 0,
                serial: originalPages[0].serial, sequence: UInt32(headerCount + index), laces: laces, body: body
            )
        }
        return stream
    }

    private func makePage(flags: UInt8, serial: UInt32, sequence: UInt32, laces: [UInt8], body: Data) -> Data {
        let granule = UInt64(sequence) * 960
        var page = Data("OggS".utf8) + Data([0, flags])
        page += Data((0..<8).map { UInt8(truncatingIfNeeded: granule >> ($0 * 8)) })
        page += little32Bytes(serial) + little32Bytes(sequence) + Data(count: 4)
        page += Data([UInt8(laces.count)] + laces) + body
        page.replaceSubrange(22..<26, with: little32Bytes(referenceChecksum(page)))
        return page
    }

    private func corrupting(_ stream: Data, with corruption: Corruption) throws -> Data {
        var data = stream
        let pages = try pages(in: stream)
        let middle = pages[headerPageCount(pages) + 2].range.lowerBound
        let last = pages[pages.count - 1]
        switch corruption {
        case .checksum: data[middle + 6] ^= 0xff
        case .sequenceGap:
            rewrite(&data, page: middle) { page in
                let skipped = little32Bytes(little32(page, at: 18) + 1)
                page.replaceSubrange(18..<22, with: skipped)
            }
        case .foreignSerial: rewrite(&data, page: middle) { $0[14] ^= 0x01 }
        case .beginningOfStream: rewrite(&data, page: middle) { $0[5] |= 2 }
        case .truncatedBody: data.removeLast(10)
        case .truncatedHeader: data.removeSubrange((last.range.lowerBound + 10)...)
        case .missingEndOfStream: rewrite(&data, page: last.range.lowerBound) { $0[5] &= ~4 }
        case .pageAfterEndOfStream:
            data += makePage(flags: 4, serial: last.serial, sequence: last.sequence + 1,
                             laces: [3], body: Data([1, 2, 3]))
        case .bytesAfterEndOfStream: data += Data(repeating: 0, count: 5)
        }
        return data
    }

    /// Edits one page's fields and re-signs it, so only the edited field is invalid.
    private func rewrite(_ data: inout Data, page offset: Int, _ edit: (inout Data) -> Void) {
        let length = 27 + Int(data[offset + 26])
            + data[(offset + 27)..<(offset + 27 + Int(data[offset + 26]))].reduce(0) { $0 + Int($1) }
        var page = Data(data[offset..<(offset + length)])
        edit(&page)
        page = zeroingCRC(page)
        page.replaceSubrange(22..<26, with: little32Bytes(referenceChecksum(page)))
        data.replaceSubrange(offset..<(offset + length), with: page)
    }

    private func zeroingCRC(_ page: Data) -> Data {
        var page = Data(page)
        page.replaceSubrange(22..<26, with: Data(count: 4))
        return page
    }

    private func maskingSequenceAndCRC(_ page: Data) -> Data {
        var page = Data(page)
        page.replaceSubrange(18..<26, with: Data(count: 8))
        return page
    }

    private func little32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }

    private func little32Bytes(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func randomData(_ count: Int, using generator: inout SplitMix64) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private func writing(_ draft: MediaMetadataEditDraft, to original: Data, _ fileExtension: String,
                         chunkSize: Int) throws -> Data {
        let target = try temporaryFile(original, fileExtension)
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try OggMetadataWriter.write(draft, to: target, chunkSize: chunkSize)
        return try Data(contentsOf: target)
    }

    private func temporaryFile(_ data: Data, _ fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("stream").appendingPathExtension(fileExtension)
        try data.write(to: url)
        return url
    }

    private func fixture(_ ext: String) -> URL {
        if let bundled = Bundle.allBundles.compactMap({ $0.url(forResource: "tag-test", withExtension: ext) }).first {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tag-test.\(ext)")
    }
}

import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

/// A copy of a fixture in its own directory, so replacement leftovers and file identity can be checked.
nonisolated struct InPlaceFixture: Sendable {
    let directory: URL
    let url: URL

    init(copying source: URL, name: String = "source") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: url)
    }

    static func resource(_ name: String, _ ext: String) throws -> URL {
        if let bundled = Bundle.allBundles.compactMap({ $0.url(forResource: name, withExtension: ext) }).first {
            return bundled
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).\(ext)")
        try #require(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    /// The inode; a replacement changes it, an in-place edit does not.
    func fileNumber(of file: URL? = nil) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: (file ?? url).path)
        return try #require(attributes[.systemFileNumber] as? Int)
    }

    func temporaryLeftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".metadata-") }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

nonisolated struct InjectedWriteError: Error {}

nonisolated enum InPlaceTestFormat: String, CaseIterable, Sendable {
    case mp4 = "m4a", flac, mp3

    /// Writes with the app's writer for this format.
    func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        switch self {
        case .mp4: try MP4MetadataWriter.write(draft, to: url)
        case .flac: try AdditionalAudioMetadata.write(draft, to: url)
        case .mp3: try ID3TagWriter.write(draft, to: url)
        }
    }

    @MainActor func title(at url: URL) throws -> String? {
        switch self {
        case .mp4: try MP4MetadataReader.read(from: url)?.values.title
        case .flac: try AdditionalAudioMetadata.read(from: url).values.title
        case .mp3: try ID3TagWriter.readMetadata(from: url)?.title
        }
    }

    /// A copy whose next save of `draft(_:)` with a short title fits in place.
    func preparedFixture() throws -> InPlaceFixture {
        switch self {
        case .mp4:
            return try InPlaceFixture(copying: InPlaceFixture.resource("untagged-aac", "m4a"))
        case .flac:
            return try InPlaceFixture(copying: InPlaceFixture.resource("tag-test", "flac"))
        case .mp3:
            let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-mp3", "mp3"))
            try write(titleDraft(String(repeating: "Long title ", count: 10)), to: fixture.url)
            return fixture
        }
    }
}

nonisolated func titleDraft(_ title: String) -> MediaMetadataEditDraft {
    MediaMetadataEditDraft(title: title, artist: "", album: "", genre: "")
}

/// Every decoded sample of the first channel.
nonisolated func decodedSamples(at url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
    ))
    try file.read(into: buffer)
    #expect(buffer.frameLength > 0)
    let samples = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
}

// MARK: - Container parsing independent of the writers

nonisolated struct TestMP4Box {
    let type: String
    let range: Range<Int>
    let contentStart: Int
}

nonisolated func parsedMP4Boxes(in data: Data, range: Range<Int>? = nil) throws -> [TestMP4Box] {
    let range = range ?? data.startIndex..<data.endIndex
    var result: [TestMP4Box] = []
    var offset = range.lowerBound
    while offset < range.upperBound {
        var headerEnd = offset + 8
        try #require(headerEnd <= range.upperBound)
        var size = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let type = try #require(String(bytes: data[(offset + 4)..<headerEnd], encoding: .isoLatin1))
        if size == 1 {
            headerEnd += 8
            try #require(headerEnd <= range.upperBound)
            size = data[(offset + 8)..<headerEnd].reduce(0) { ($0 << 8) | Int($1) }
        } else if size == 0 {
            size = range.upperBound - offset
        }
        try #require(size >= headerEnd - offset && size <= range.upperBound - offset)
        result.append(TestMP4Box(type: type, range: offset..<(offset + size), contentStart: headerEnd))
        offset += size
    }
    return result
}

/// The box at `path`, following the first box of each type.
nonisolated func mp4Box(_ path: [String], in data: Data) throws -> TestMP4Box {
    var range = data.startIndex..<data.endIndex
    var found: TestMP4Box?
    for type in path {
        let box = try #require(try parsedMP4Boxes(in: data, range: range).first { $0.type == type }, "\(type)")
        found = box
        range = box.contentStart..<box.range.upperBound
    }
    return try #require(found)
}

nonisolated func mp4Box(_ type: String, _ payload: Data) -> Data {
    let size = UInt32(payload.count + 8)
    return Data((0..<4).map { UInt8(truncatingIfNeeded: size >> ((3 - $0) * 8)) }) + Data(type.utf8) + payload
}

nonisolated struct TestFLACBlock {
    let type: UInt8
    let isLast: Bool
    let range: Range<Int>
}

nonisolated func flacBlocks(in data: Data) throws -> [TestFLACBlock] {
    try #require(data.prefix(4) == Data("fLaC".utf8))
    var blocks: [TestFLACBlock] = []
    var offset = 4
    while blocks.last?.isLast != true {
        try #require(offset + 4 <= data.count)
        let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        try #require(offset + 4 + length <= data.count)
        blocks.append(TestFLACBlock(
            type: data[offset] & 0x7f, isLast: data[offset] & 0x80 != 0, range: offset..<(offset + 4 + length)
        ))
        offset += 4 + length
    }
    return blocks
}

/// The size of the ID3v2 tag at the start of `data`, footer included.
nonisolated func id3TagSize(in data: Data) throws -> Int {
    try #require(data.prefix(3) == Data("ID3".utf8))
    let size = data[6..<10].reduce(0) { ($0 << 7) | Int($1 & 0x7f) }
    return 10 + size + (data[3] == 4 && data[5] & 0x10 != 0 ? 10 : 0)
}

import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MP4MetadataLayoutTests {
    @Test func untaggedAACReadsBackThroughAVFoundationAndKeepsAudio() async throws {
        let fixture = try LayoutFixture()
        defer { fixture.remove() }
        try FileManager.default.copyItem(at: resource("untagged-aac", extension: "m4a"), to: fixture.url)
        let original = try Data(contentsOf: fixture.url)
        #expect(try children(in: content(of: ["moov"], in: original)).contains { $0.type == "udta" } == false)
        let audioBefore = try decodedAudio(at: fixture.url)

        try MP4MetadataWriter.write(draft("New AAC title"), to: fixture.url)

        let metadata = try await AVURLAsset(url: fixture.url).load(.commonMetadata)
        let title = try #require(metadata.first { $0.commonKey == .commonKeyTitle })
        #expect(try await title.load(.stringValue) == "New AAC title")
        #expect(try decodedAudio(at: fixture.url) == audioBefore)
        #expect(try content(of: ["mdat"], in: Data(contentsOf: fixture.url)) == content(of: ["mdat"], in: original))
    }

    @Test func nativeFragmentedVideoRejectsGrowthAndRemainsReadableAfterSeek() async throws {
        let fixture = try LayoutFixture()
        defer { fixture.remove() }
        try FileManager.default.copyItem(at: resource("fragmented-video", extension: "mp4"), to: fixture.url)
        let original = try Data(contentsOf: fixture.url)
        #expect(try children(in: original).filter { $0.type == "moof" }.count >= 2)
        let timesBefore = try await decodedVideoTimes(at: fixture.url, startingAt: 0)
        let seekTimesBefore = try await decodedVideoTimes(at: fixture.url, startingAt: 1)
        #expect(timesBefore.count >= 60)
        #expect(seekTimesBefore.isEmpty == false)
        #expect(seekTimesBefore.allSatisfy { $0 >= 1 })

        #expect(throws: MediaMetadataEditError.unsupportedMP4MetadataLayout) {
            try MP4MetadataWriter.write(draft("New fragmented video title"), to: fixture.url)
        }

        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(try await decodedVideoTimes(at: fixture.url, startingAt: 0) == timesBefore)
        #expect(try await decodedVideoTimes(at: fixture.url, startingAt: 1) == seekTimesBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["source.mp4"])
    }

    @Test(arguments: [false, true])
    func newMetadataIncludesITunesHandler(existingUdta: Bool) throws {
        let fixture = try LayoutFixture()
        defer { fixture.remove() }
        let original = box("moov", existingUdta ? box("udta", Data()) : Data())
            + box("mdat", Data([1, 2, 3]))
        try original.write(to: fixture.url)

        try MP4MetadataWriter.write(draft("Title"), to: fixture.url)

        let written = try Data(contentsOf: fixture.url)
        let meta = try content(of: ["moov", "udta", "meta"], in: written)
        let children = try children(in: meta, startingAt: 4)
        #expect(children.map(\.type) == ["hdlr", "ilst"])
        let handler = try #require(children.first(where: { $0.type == "hdlr" }))
        #expect(handler.data.count == 33)
        #expect(Data(handler.data[8..<16]) == Data(repeating: 0, count: 8))
        #expect(Data(handler.data[16..<24]) == Data("mdirappl".utf8))
        #expect(Data(handler.data[24..<33]) == Data(repeating: 0, count: 9))
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == "Title")
        #expect(try content(of: ["mdat"], in: written) == Data([1, 2, 3]))
    }

    @Test(arguments: ["moof", "mfra", "sidx", "mvex"])
    func growingFragmentedLayoutIsRejected(marker: String) throws {
        try expectRejected(marker: marker, oldTitle: "Old", newTitle: "Much longer title")
    }

    @Test(arguments: 1...7)
    func smallShrinkCannotShiftFragments(bytes: Int) throws {
        try expectRejected(marker: "moof", oldTitle: "Title" + String(repeating: "x", count: bytes), newTitle: "Title")
    }

    @Test(arguments: ["moof", "mfra", "sidx", "mvex"], [0, 8, 40])
    func fixedSizeEditPreservesFragmentBytesAndPositions(marker: String, shrink: Int) throws {
        let fixture = try LayoutFixture()
        defer { fixture.remove() }
        let original = movie(title: "Title" + String(repeating: "x", count: shrink), marker: marker)
        try original.write(to: fixture.url)

        try MP4MetadataWriter.write(draft("Other"), to: fixture.url)

        let written = try Data(contentsOf: fixture.url)
        let originalBoxes = try children(in: original)
        let writtenBoxes = try children(in: written)
        #expect(written.count == original.count)
        #expect(writtenBoxes.map(\.offset) == originalBoxes.map(\.offset))
        #expect(writtenBoxes.dropFirst().map(\.data) == originalBoxes.dropFirst().map(\.data))
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.title == "Other")
        if marker == "mvex" {
            #expect(try content(of: ["moov", "mvex"], in: written) == Data([0, 1, 2, 3]))
        }
    }

    @Test func existingHandlerAndUnknownMetadataArePreserved() throws {
        let fixture = try LayoutFixture()
        defer { fixture.remove() }
        let handler = box("hdlr", Data(repeating: 7, count: 25))
        let unknown = box("----", Data([5, 4, 3, 2, 1]))
        let meta = box("meta", Data(repeating: 0, count: 4) + handler + unknown + item("Old"))
        try box("moov", box("udta", meta)).write(to: fixture.url)

        try MP4MetadataWriter.write(draft("New"), to: fixture.url)

        let written = try content(of: ["moov", "udta", "meta"], in: Data(contentsOf: fixture.url))
        let preserved = try children(in: written, startingAt: 4).filter { $0.type != "ilst" }
        #expect(preserved.map(\.data) == [handler, unknown])
    }

    private func expectRejected(marker: String, oldTitle: String, newTitle: String) throws {
        let fixture = try LayoutFixture()
        defer { fixture.remove() }
        let original = movie(title: oldTitle, marker: marker)
        try original.write(to: fixture.url)

        #expect(throws: MediaMetadataEditError.unsupportedMP4MetadataLayout) {
            try MP4MetadataWriter.write(draft(newTitle), to: fixture.url)
        }

        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["source.mp4"])
    }

    private func draft(_ title: String) -> MediaMetadataEditDraft {
        MediaMetadataEditDraft(title: title, artist: "", album: "", genre: "")
    }

    private func movie(title: String, marker: String) -> Data {
        let meta = box("meta", Data(repeating: 0, count: 4) + item(title))
        let fragment = box(marker, Data([0, 1, 2, 3]))
        let moov = box("moov", box("udta", meta) + (marker == "mvex" ? fragment : Data()))
        return moov + (marker == "mvex" ? Data() : fragment) + box("mdat", Data([4, 5, 6]))
    }

    private func item(_ title: String) -> Data {
        let payload = Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(title.utf8)
        return box("ilst", box("©nam", box("data", payload)))
    }

    private func box(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(payload.count + 8)
        let header = Data((0..<4).map { UInt8(truncatingIfNeeded: size >> ((3 - $0) * 8)) })
        let typeData = type == "©nam" ? Data([0xA9, 0x6E, 0x61, 0x6D]) : Data(type.utf8)
        return header + typeData + payload
    }

    private func content(of path: [String], in data: Data) throws -> Data {
        var content = data
        for type in path {
            let child = try #require(try children(in: content).first(where: { $0.type == type }))
            content = Data(child.data.dropFirst(8))
        }
        return content
    }

    private func children(in data: Data, startingAt start: Int = 0) throws -> [LayoutBox] {
        var result: [LayoutBox] = []
        var offset = start
        while offset < data.count {
            var headerEnd = offset + 8
            try #require(headerEnd <= data.count)
            var size = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let type = try #require(String(bytes: data[(offset + 4)..<headerEnd], encoding: .utf8))
            if size == 1 {
                headerEnd += 8
                try #require(headerEnd <= data.count)
                size = data[(offset + 8)..<headerEnd].reduce(0) { ($0 << 8) | Int($1) }
            } else if size == 0 {
                size = data.count - offset
            }
            try #require(size >= headerEnd - offset && size <= data.count - offset)
            result.append(LayoutBox(
                type: type,
                offset: offset,
                data: Data(data[offset..<(offset + size)])
            ))
            offset += size
        }
        return result
    }

    private func resource(_ name: String, extension ext: String) throws -> URL {
        try #require(Bundle.allBundles.compactMap { $0.url(forResource: name, withExtension: ext) }.first)
    }

    private func decodedAudio(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768))
        try file.read(into: buffer)
        #expect(buffer.frameLength > 0)
        let samples = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    private func decodedVideoTimes(at url: URL, startingAt seconds: Double) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: seconds, preferredTimescale: 30), duration: .positiveInfinity
        )
        try #require(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            #expect(CMSampleBufferGetImageBuffer(sample) != nil)
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        #expect(reader.status == .completed)
        return times
    }
}

private struct LayoutBox {
    let type: String
    let offset: Int
    let data: Data
}

private struct LayoutFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("source.mp4") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

/// Exports from local files stand in for Music library assets: the exporter only sees an `AVURLAsset`.
struct MusicLibraryTrackExporterTests {
    @Test func copiesPCMSourceIntoWAVWithoutTranscoding() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeAudio(named: "source.wav", in: directory, formatID: kAudioFormatLinearPCM)

        let output = try await MusicLibraryTrackExporter.export(assetURL: source, to: directory, baseName: "1")

        #expect(output.format == .wav)
        #expect(output.isTranscoded == false)
        #expect(output.url.lastPathComponent == "1.wav")
        let file = try AVAudioFile(forReading: output.url)
        #expect(file.length == 44_100)
        #expect(formatID(of: file) == kAudioFormatLinearPCM)
        #expect(abs(output.duration - 1) < 0.01)
    }

    @Test func keepsAIFFContainerForAIFFSources() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeAudio(named: "source.aiff", in: directory, formatID: kAudioFormatLinearPCM)

        let output = try await MusicLibraryTrackExporter.export(assetURL: source, to: directory, baseName: "2")

        #expect(output.format == .aiff)
        #expect(output.isTranscoded == false)
        #expect(try AVAudioFile(forReading: output.url).length == 44_100)
    }

    @Test(arguments: [kAudioFormatMPEG4AAC, kAudioFormatAppleLossless])
    func keepsM4AEncodings(formatID sourceFormatID: AudioFormatID) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeAudio(named: "source.m4a", in: directory, formatID: sourceFormatID)

        let output = try await MusicLibraryTrackExporter.export(assetURL: source, to: directory, baseName: "3")

        #expect(output.format == .m4a)
        #expect(output.isTranscoded == false)
        let file = try AVAudioFile(forReading: output.url)
        #expect(formatID(of: file) == sourceFormatID)
        #expect(file.length == 44_100)
    }

    @Test func copiesMPEGFramesIntoABareMP3Stream() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try mp3Fixture()
        let sourceFile = try AVAudioFile(forReading: source)

        let output = try await MusicLibraryTrackExporter.export(assetURL: source, to: directory, baseName: "4")

        #expect(output.format == .mp3)
        #expect(output.isTranscoded == false)
        let bytes = try Data(contentsOf: output.url)
        #expect(bytes.count > 1_000)
        // Every MPEG audio frame starts with an 11-bit sync word.
        #expect(bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
        let file = try AVAudioFile(forReading: output.url)
        #expect(formatID(of: file) == kAudioFormatMPEGLayer3)
        #expect(abs(Double(file.length) - Double(sourceFile.length)) <= 1_152 * 2)
    }

    @Test func exportedCopiesAcceptEmbeddedMetadata() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var track = MusicLibraryTrack(id: 42)
        track.title = "Music Title"
        track.artist = "Music Artist"
        let sources = [
            try mp3Fixture(),
            try writeAudio(named: "source.m4a", in: directory, formatID: kAudioFormatMPEG4AAC),
            try writeAudio(named: "source.wav", in: directory, formatID: kAudioFormatLinearPCM)
        ]
        for (index, source) in sources.enumerated() {
            let output = try await MusicLibraryTrackExporter.export(
                assetURL: source, to: directory, baseName: "meta-\(index)"
            )
            #expect(await LibraryService.embedMusicLibraryMetadata(of: track, into: output.url))
            let metadata = try await AVURLAsset(url: output.url).load(.commonMetadata)
            let title = try await AVMetadataItem.metadataItems(
                from: metadata, filteredByIdentifier: .commonIdentifierTitle
            ).first?.load(.stringValue)
            #expect(title == "Music Title", "\(output.url.lastPathComponent)")
            #expect(try AVAudioFile(forReading: output.url).length > 0)
        }
    }

    @Test func cancelledExportLeavesNoFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeAudio(named: "source.wav", in: directory, formatID: kAudioFormatLinearPCM)
        let task = Task {
            try await MusicLibraryTrackExporter.export(assetURL: source, to: directory, baseName: "5")
        }
        task.cancel()

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.wav"])
    }

    @Test func missingSourceIsReported() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("missing.m4a")

        await #expect(throws: (any Error).self) {
            try await MusicLibraryTrackExporter.export(assetURL: source, to: directory, baseName: "6")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryTrackExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func mp3Fixture() throws -> URL {
        try #require(Bundle(for: MusicLibraryTestBundleToken.self).url(
            forResource: "music-library-source", withExtension: "mp3"
        ))
    }

    private func formatID(of file: AVAudioFile) -> AudioFormatID? {
        file.fileFormat.streamDescription.pointee.mFormatID
    }
}

final class MusicLibraryTestBundleToken {}

func writeAudio(named name: String, in directory: URL, formatID: AudioFormatID) throws -> URL {
    let url = directory.appendingPathComponent(name)
    var settings: [String: Any] = [
        AVFormatIDKey: formatID, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2
    ]
    if formatID == kAudioFormatLinearPCM {
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = url.pathExtension == "aiff"
    }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frameCount: AVAudioFrameCount = 44_100
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    for channel in 0..<2 {
        let samples = try #require(buffer.floatChannelData?[channel])
        for index in 0..<Int(frameCount) {
            samples[index] = sinf(Float(index) * 0.05) * 0.3
        }
    }
    try file.write(from: buffer)
    return url
}

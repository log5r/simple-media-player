import AVFoundation
import Foundation
import SFBAudioEngine
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@Suite(.serialized)
struct ExtendedAudioValidationTests {
    @Test(arguments: ["wma", "wv", "ape"])
    func validatesWithoutCreatingPCMCache(ext: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.\(ext)")
        try FileManager.default.copyItem(at: fixture(ext), to: source)
        let cache = try #require(ExtendedAudioSource.cacheURL(for: source))
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
        try ExtendedAudioSource.validate(for: source)
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
    }

    @Test func rejectsCorruptionAfterInitiallyDecodableWMAFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try lateCorruptWMA(in: directory)
        #expect(try ExtendedAudioSource.info(for: source, kind: .wma).duration > 0)
        let partialOutput = directory.appendingPathComponent("partial.caf")
        #expect(throws: (any Error).self) {
            try SMPFFmpegAudio.decode(source, toCAF: partialOutput, maxBytes: 1_024 * 1_024, shouldCancel: { false })
        }
        #expect(try AVAudioFile(forReading: partialOutput).length > 0)
        #expect(throws: (any Error).self) { try ExtendedAudioSource.validate(for: source) }
        #expect(throws: (any Error).self) { try ExtendedAudioSource.readableURL(for: source) }
        let cache = try #require(ExtendedAudioSource.cacheURL(for: source))
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
    }

    @Test func validationEnforcesDecodedSizeLimit() {
        #expect(throws: (any Error).self) {
            try SMPFFmpegAudio.validate(fixture("wma"), maxBytes: 4, shouldCancel: { false })
        }
    }

    @Test func validationAndDecodeIncludeCAFHeaderInSizeLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = fixture("wma")
        let complete = directory.appendingPathComponent("complete.caf")
        try SMPFFmpegAudio.decode(source, toCAF: complete, maxBytes: 1_024 * 1_024, shouldCancel: { false })
        let audio = try AVAudioFile(forReading: complete)
        let physicalBytes = try fileBytes(at: complete)
        let maximum = try SMPAudioCacheSizeLimit.maximumFrames(for: audio.processingFormat, maxFileBytes: physicalBytes)
        #expect(maximum.int64Value == audio.length)
        try SMPFFmpegAudio.validate(source, maxBytes: physicalBytes, shouldCancel: { false })
        let exact = directory.appendingPathComponent("exact.caf")
        try SMPFFmpegAudio.decode(source, toCAF: exact, maxBytes: physicalBytes, shouldCancel: { false })
        #expect(try fileBytes(at: exact) == physicalBytes)
        #expect(throws: (any Error).self) {
            try SMPFFmpegAudio.validate(source, maxBytes: physicalBytes - 1, shouldCancel: { false })
        }
        let tooLarge = directory.appendingPathComponent("too-large.caf")
        #expect(throws: (any Error).self) {
            try SMPFFmpegAudio.decode(source, toCAF: tooLarge, maxBytes: physicalBytes - 1, shouldCancel: { false })
        }
    }

    @Test(arguments: [
        (AVAudioCommonFormat.pcmFormatFloat32, AVAudioChannelCount(1), false),
        (AVAudioCommonFormat.pcmFormatFloat32, AVAudioChannelCount(2), false),
        (AVAudioCommonFormat.pcmFormatInt16, AVAudioChannelCount(2), false),
        (AVAudioCommonFormat.pcmFormatInt16, AVAudioChannelCount(2), true)
    ])
    func frameBudgetMatchesPhysicalCAFSize(
        commonFormat: AVAudioCommonFormat, channels: AVAudioChannelCount, interleaved: Bool
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(
            commonFormat: commonFormat, sampleRate: 44_100, channels: channels, interleaved: interleaved
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = buffer.frameCapacity
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            audioBuffer.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(audioBuffer.mDataByteSize))
        }
        let destination = directory.appendingPathComponent("probe.caf")
        try writeCAF(buffer: buffer, to: destination)
        let physicalBytes = try fileBytes(at: destination)
        let exact = try SMPAudioCacheSizeLimit.maximumFrames(for: format, maxFileBytes: physicalBytes)
        let smaller = try SMPAudioCacheSizeLimit.maximumFrames(for: format, maxFileBytes: physicalBytes - 1)
        #expect(exact.int64Value == 512)
        #expect(smaller.int64Value == 511)
    }

    @Test func rejectsWavPackEndingBeforeDeclaredFrameCount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("truncated.wv")
        // The fixture declares 44,100 frames in two blocks. Keep only its first 22,050-frame block.
        try Data(contentsOf: fixture("wv")).prefix(14_744).write(to: source)
        #expect(try ExtendedAudioSource.info(for: source, kind: .wavPack).duration > 0)
        let decoder = try AudioDecoder(url: source)
        try decoder.open()
        defer { try? decoder.close() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 16_384))
        try decoder.decode(into: buffer, length: buffer.frameCapacity)
        #expect(buffer.frameLength > 0)
        #expect(decoder.length == 44_100)
        #expect(throws: (any Error).self) { try ExtendedAudioSource.validate(for: source) }
        #expect(throws: (any Error).self) { try ExtendedAudioSource.readableURL(for: source) }
        let cache = try #require(ExtendedAudioSource.cacheURL(for: source))
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
    }

    @Test(arguments: ["wma", "wv"])
    func cancelledValidationDoesNotCreatePCMCache(ext: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.\(ext)")
        try FileManager.default.copyItem(at: fixture(ext), to: source)
        let validation = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try ExtendedAudioSource.validate(for: source)
        }
        await #expect(throws: CancellationError.self) { try await validation.value }
        let cache = try #require(ExtendedAudioSource.cacheURL(for: source))
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
    }

    @MainActor
    @Test func importRejectsLateCorruptionAndRemovesManagedCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try lateCorruptWMA(in: directory)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let managed = directory.appendingPathComponent("Managed")
        let service = LibraryService(mediaDirectoryURL: managed)
        await service.importFiles(from: [source], into: container.mainContext, existingItems: [])
        #expect(service.lastImportErrors.count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<MediaItem>()).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: managed.path).isEmpty)
    }

    private func lateCorruptWMA(in directory: URL) throws -> URL {
        var data = try Data(contentsOf: fixture("wma"))
        // Preserve the ASF headers and the first two valid packets; damage the third packet's audio payload.
        data.replaceSubrange(7_270..<8_013, with: Data(repeating: 0xFF, count: 743))
        let source = directory.appendingPathComponent("late-corruption.wma")
        try data.write(to: source)
        return source
    }

    private func fileBytes(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.size] as? NSNumber).int64Value
    }

    private func writeCAF(buffer: AVAudioPCMBuffer, to url: URL) throws {
        let format = buffer.format
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }

    private func fixture(_ ext: String, baseName: String = "extended-test") -> URL {
        if let bundled = Bundle.allBundles.compactMap({
            $0.url(forResource: baseName, withExtension: ext)
        }).first {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(baseName).\(ext)")
    }
}

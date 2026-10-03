import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import SimpleMediaPlayer

@MainActor
struct ArtworkProcessingTests {
    @Test(arguments: [1, 6])
    func thumbnailProducesBoundedJPEGAndAppliesOrientation(orientation: Int) async throws {
        let original = try makeArtwork(
            width: 1_200,
            height: 800,
            orientation: orientation,
            type: orientation == 6 ? .jpeg : .png
        )

        let thumbnail = try #require(await ArtworkProcessor().thumbnail(from: original))

        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == (orientation == 6 ? 400 : 600))
        #expect(image.height == (orientation == 6 ? 600 : 400))
    }

    @Test func failedDownsamplingIsHandledForBothEmbeddedAndSelectedArtwork() async throws {
        let directory = try ArtworkTestDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("invalid.jpg")
        let invalid = Data("not an image".utf8)
        try invalid.write(to: url)
        let processor = ArtworkProcessor(downsample: { _, _ in nil })

        #expect(await processor.thumbnail(from: invalid) == nil)
        do {
            _ = try await processor.load(from: url)
            Issue.record("Invalid selected artwork should throw an invalidArtwork error")
        } catch {
            #expect(error as? MediaMetadataEditError == .invalidArtwork)
        }
    }

    @Test func mainActorCallerRunsThumbnailProcessingOnWorker() async throws {
        let input = Data("embedded artwork".utf8)
        let probe = ArtworkProcessingProbe()
        let processor = ArtworkProcessor(downsample: { data, maxPixelSize in
            probe.process(data, maxPixelSize: maxPixelSize)
        })
        expectMainThreadCaller()

        let result = await processor.thumbnail(from: input)

        #expect(result == probe.output)
        expectWorkerProcessing(probe, input: input)
    }

    @Test func selectedArtworkReadsFileAndProcessesOnWorker() async throws {
        let directory = try ArtworkTestDirectory()
        defer { directory.remove() }
        let input = Data("selected artwork".utf8)
        let url = directory.url.appendingPathComponent("selected.png")
        try input.write(to: url)
        let probe = ArtworkProcessingProbe()
        let service = LibraryService(artworkProcessor: ArtworkProcessor(downsample: { data, maxPixelSize in
            probe.process(data, maxPixelSize: maxPixelSize)
        }))
        expectMainThreadCaller()

        let result = try await service.loadArtwork(from: url)

        #expect(result == probe.output)
        expectWorkerProcessing(probe, input: input)
    }

    @Test func importedArtworkIsProcessedOnWorkerBeforePersistence() async throws {
        let directory = try ArtworkTestDirectory()
        defer { directory.remove() }
        let input = try makeArtwork(width: 1_200, height: 800)
        let sourceURL = directory.url.appendingPathComponent("source.mp4")
        try makeAudioWithArtwork(at: sourceURL, artwork: input)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let probe = ArtworkProcessingProbe()
        let service = LibraryService(
            mediaDirectoryURL: directory.url.appendingPathComponent("Media", isDirectory: true),
            artworkProcessor: ArtworkProcessor(downsample: { data, maxPixelSize in
                probe.process(data, maxPixelSize: maxPixelSize)
            })
        )

        await service.importFiles(from: [sourceURL], into: container.mainContext, existingItems: [])

        #expect(service.lastImportErrors.isEmpty)
        let context = ModelContext(container)
        let imported = try #require(context.fetch(FetchDescriptor<MediaItem>()).first)
        #expect(imported.artworkData == probe.output)
        #expect(imported.isVideo)
        expectWorkerProcessing(probe, input: input)
    }

    @Test func metadataDraftProcessesEmbeddedArtworkOnWorker() async throws {
        let directory = try ArtworkTestDirectory()
        defer { directory.remove() }
        let input = try makeArtwork(width: 1_200, height: 800)
        let sourceURL = directory.url.appendingPathComponent("source.mp4")
        try makeAudioWithArtwork(at: sourceURL, artwork: input)
        let item = MediaItem(
            title: "Original",
            duration: 0.1,
            isVideo: true,
            bookmarkData: Data([0xFF]),
            fileName: sourceURL.lastPathComponent
        )
        let probe = ArtworkProcessingProbe()
        let service = LibraryService(
            mediaDirectoryURL: directory.url,
            artworkProcessor: ArtworkProcessor(downsample: { data, maxPixelSize in
                probe.process(data, maxPixelSize: maxPixelSize)
            })
        )

        let draft = try await service.editableMetadataDraft(for: item)

        #expect(draft.artworkData == probe.output)
        #expect(item.artworkData == nil)
        expectWorkerProcessing(probe, input: input)
    }

    private func expectMainThreadCaller() {
        #expect(Thread.isMainThread)
    }

    private func expectWorkerProcessing(_ probe: ArtworkProcessingProbe, input: Data) {
        let calls = probe.calls
        #expect(calls.count == 1)
        #expect(calls.first?.data == input)
        #expect(calls.first?.maxPixelSize == 600)
        #expect(calls.first?.wasMainThread == false)
    }

    private func makeArtwork(width: Int, height: Int, orientation: Int = 1, type: UTType = .png) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try #require(context.makeImage())
        let data = try #require(CFDataCreateMutable(nil, 0))
        let destination = try #require(CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeAudioWithArtwork(at url: URL, artwork: Data) throws {
        let audioURL = url.deletingPathExtension().appendingPathExtension("m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let samples = try #require(buffer.floatChannelData?.pointee)
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        let encoder = try CoreAudioFileEncoder(outputURL: audioURL, format: .aac, processingFormat: format)
        try encoder.encode(buffer: buffer)
        try encoder.finish()
        try FileManager.default.moveItem(at: audioURL, to: url)
        let draft = MediaMetadataEditDraft(
            title: "Artwork fixture",
            artist: "Artist",
            album: "Album",
            genre: "",
            artworkData: artwork,
            editsArtwork: true
        )
        try MP4MetadataWriter.write(draft, to: url)
    }
}

nonisolated private final class ArtworkProcessingProbe: @unchecked Sendable {
    struct Call {
        let data: Data
        let maxPixelSize: CGFloat
        let wasMainThread: Bool
    }

    let output = Data("processed artwork".utf8)
    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func process(_ data: Data, maxPixelSize: CGFloat) -> Data? {
        lock.withLock {
            recordedCalls.append(Call(data: data, maxPixelSize: maxPixelSize, wasMainThread: Thread.isMainThread))
        }
        return output
    }
}

private struct ArtworkTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkProcessingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

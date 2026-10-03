import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import SimpleMediaPlayer

@MainActor
struct EditableMetadataDraftCancellationTests {
    @Test func alreadyCancelledRequestDoesNotReadArtworkOrEmbeddedMetadata() async throws {
        let probe = MetadataDraftReadProbe(blocks: false)
        let fixture = try MetadataDraftFixture(probe: probe)
        defer { fixture.remove() }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.editableMetadataDraft(for: fixture.item)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.readCount == 0)
        #expect(probe.thumbnailCount == 0)
    }

    @Test(arguments: [false, true])
    func cancellationDuringArtworkReadStopsBeforeEmbeddedMetadata(readFails: Bool) async throws {
        let probe = MetadataDraftReadProbe(readFails: readFails)
        let fixture = try MetadataDraftFixture(probe: probe)
        defer { fixture.remove() }
        let task = Task { @MainActor in
            try await fixture.service.editableMetadataDraft(for: fixture.item)
        }
        defer { task.cancel(); probe.release() }
        try await probe.waitUntilReading()

        task.cancel()
        probe.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.readCount == 1)
        #expect(probe.thumbnailCount == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func replacementOrDeletionInvalidatesDraftWithoutTaskCancellation(deleteItem: Bool, readFails: Bool) async throws {
        let probe = MetadataDraftReadProbe(readFails: readFails)
        let fixture = try MetadataDraftFixture(probe: probe)
        defer { fixture.remove() }
        let task = Task { @MainActor in
            try await fixture.service.editableMetadataDraft(for: fixture.item)
        }
        defer { task.cancel(); probe.release() }
        try await probe.waitUntilReading()

        if deleteItem {
            fixture.context.delete(fixture.item)
        } else {
            fixture.item.artworkData = Data([4, 5, 6])
        }
        try fixture.context.save()
        // The source file remains valid: stopping must follow item invalidation, not a file-read failure.
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        probe.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.thumbnailCount == 0)
    }

    @Test(arguments: BulkDraftReadInvalidation.allCases, [false, true])
    private func invalidatedArtworkReadCannotWriteABulkTitleEdit(
        invalidation: BulkDraftReadInvalidation,
        readFails: Bool
    ) async throws {
        let probe = MetadataDraftReadProbe(readFails: readFails)
        let fixture = try MetadataDraftFixture(probe: probe)
        defer { fixture.remove() }
        let sourceBytes = try Data(contentsOf: fixture.sourceURL)
        var draft = MediaMetadataEditDraft(item: fixture.item)
        draft.title = "Bulk replacement title"
        let patch = MediaMetadataEditPatch(fields: [.title], draft: draft)
        let task = Task { @MainActor in
            await fixture.service.updateEmbeddedMetadata(
                for: [fixture.item], patch: patch, in: fixture.context
            )
        }
        defer { task.cancel(); probe.release() }
        try await probe.waitUntilReading()

        switch invalidation {
        case .cancellation:
            task.cancel()
        case .replacement:
            fixture.item.artworkData = Data([4, 5, 6])
            try fixture.context.save()
        case .deletion:
            fixture.context.delete(fixture.item)
            try fixture.context.save()
        }
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        probe.release()
        let result = await task.value

        #expect(result.updatedCount == 0)
        #expect(result.failedCount == 1)
        #expect(result.failures.first?.fileName == fixture.sourceURL.lastPathComponent)
        #expect(try Data(contentsOf: fixture.sourceURL) == sourceBytes)
        let persisted = try ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>())
        if invalidation == .deletion {
            #expect(persisted.isEmpty)
        } else {
            #expect(fixture.item.title == "Model title")
            #expect(persisted.first?.title == "Model title")
        }
        #expect(probe.thumbnailCount == 0)
    }

    @Test func ordinaryArtworkReadFailureStillLoadsEmbeddedWAVMetadata() async throws {
        let probe = MetadataDraftReadProbe(blocks: false, readFails: true)
        let fixture = try MetadataDraftFixture(probe: probe, useWAV: true)
        defer { fixture.remove() }

        let draft = try await fixture.service.editableMetadataDraft(for: fixture.item)

        #expect(probe.readCount == 1)
        #expect(draft.title == "Embedded title")
        #expect(draft.artist == "Embedded artist")
        #expect(draft.album == "Embedded album")
        #expect(draft.lyrics == "Embedded lyrics")
        #expect(draft.artworkData == fixture.embeddedArtwork)
        #expect(fixture.item.title == "Model title")
        #expect(fixture.item.lyricsRaw == "Model lyrics")
    }
}

nonisolated private enum BulkDraftReadInvalidation: CaseIterable {
    case cancellation
    case replacement
    case deletion
}

@MainActor
private struct MetadataDraftFixture {
    let directory: URL
    let sourceURL: URL
    let embeddedArtwork: Data
    let container: ModelContainer
    let service: LibraryService
    let item: MediaItem
    var context: ModelContext { container.mainContext }

    init(probe: MetadataDraftReadProbe, useWAV: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        sourceURL = directory.appendingPathComponent(useWAV ? "source.wav" : "source.mp4")
        embeddedArtwork = try makeDraftArtwork()
        try writeDraftAudio(to: sourceURL, useWAV: useWAV)
        let metadata = MediaMetadataEditDraft(
            title: "Embedded title", artist: "Embedded artist", album: "Embedded album", genre: "",
            artworkData: embeddedArtwork, lyrics: "Embedded lyrics", editsArtwork: true, editsLyrics: true
        )
        if useWAV {
            try WAVMetadataWriter.write(metadata, to: sourceURL)
        } else {
            try MP4MetadataWriter.write(metadata, to: sourceURL)
        }
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        item = MediaItem(
            title: "Model title", artist: "Model artist", album: "Model album", duration: 0.1,
            isVideo: useWAV == false, lyricsRaw: "Model lyrics", bookmarkData: Data([0xFF]),
            artworkData: Data([1, 2, 3]), fileName: sourceURL.lastPathComponent
        )
        container.mainContext.insert(item)
        try container.mainContext.save()
        service = LibraryService(
            mediaDirectoryURL: directory,
            artworkProcessor: ArtworkProcessor(downsample: probe.thumbnail),
            artworkLoader: LibraryArtworkLoader(read: probe.read)
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func writeDraftAudio(to url: URL, useWAV: Bool) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
    buffer.frameLength = 4_410
    let samples = try #require(buffer.floatChannelData?[0])
    samples.update(repeating: 0.1, count: Int(buffer.frameLength))
    if useWAV {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    } else {
        let audioURL = url.deletingPathExtension().appendingPathExtension("m4a")
        let encoder = try CoreAudioFileEncoder(outputURL: audioURL, format: .aac, processingFormat: format)
        try encoder.encode(buffer: buffer)
        try encoder.finish()
        try FileManager.default.moveItem(at: audioURL, to: url)
    }
}

private func makeDraftArtwork() throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let image = try #require(context.makeImage())
    let data = try #require(CFDataCreateMutable(nil, 0))
    let destination = try #require(CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

nonisolated private final class MetadataDraftReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blocks: Bool
    private let readFails: Bool
    private var reads = 0
    private var thumbnails = 0

    init(blocks: Bool = true, readFails: Bool = false) {
        self.blocks = blocks
        self.readFails = readFails
    }

    var readCount: Int { lock.withLock { reads } }
    var thumbnailCount: Int { lock.withLock { thumbnails } }

    func read(_ artworkID: UUID, _ container: ModelContainer) throws -> Data? {
        lock.withLock { reads += 1 }
        if blocks {
            guard gate.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        }
        if readFails { throw CocoaError(.fileReadUnknown) }
        return Data([1, 2, 3])
    }

    func thumbnail(_ data: Data, _ maxPixelSize: CGFloat) -> Data? {
        lock.withLock { thumbnails += 1 }
        return data
    }

    func release() { gate.signal() }

    func waitUntilReading() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while readCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(readCount == 1, "The draft artwork reader did not start before the deadline")
    }
}

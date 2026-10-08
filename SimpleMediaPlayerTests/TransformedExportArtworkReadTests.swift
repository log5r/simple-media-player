import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct TransformedExportArtworkReadTests {
    @Test(arguments: [false, true])
    func transformedCopyPreservesClearedAndLiteralUnknownTagValues(literal: Bool) async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let initial = MediaMetadataEditDraft(
            title: "", artist: literal ? "Unknown Artist" : "", album: literal ? "Unknown Album" : "", genre: ""
        )
        fixture.source.artist = "Unknown Artist"
        fixture.source.album = "Unknown Album"
        fixture.source.setEditedTextMetadata(initial)
        try fixture.context.save()
        let renderer = ControlledExportRenderer(behavior: .finishImmediately)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)

        let copy = try await fixture.export(using: exporter)

        let embedded = try AdditionalAudioMetadata.read(
            from: fixture.mediaDirectory.appendingPathComponent(copy.fileName)
        )
        #expect(embedded.values.title == "Rendered")
        #expect(embedded.values.artist == (literal ? "Unknown Artist" : nil))
        #expect(embedded.values.album == (literal ? "Unknown Album" : nil))
        let reloaded = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>()).first {
            $0.id == copy.id
        })
        let draft = MediaMetadataEditDraft(item: reloaded)
        #expect(draft.title == "Rendered")
        #expect(draft.artist == initial.artist)
        #expect(draft.album == initial.album)
    }

    @Test func artworkReadFailureReportsErrorWithoutStartingRenderer() async throws {
        let readError = CocoaError(.fileReadUnknown)
        let loader = LibraryArtworkLoader { _, _ in throw readError }
        let fixture = try TransformedExportFixture(artworkLoader: loader)
        defer { fixture.remove() }
        fixture.source.artworkData = Data([1, 2, 3])
        try fixture.context.save()
        let renderer = ControlledExportRenderer(behavior: .finishImmediately)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)

        await #expect(throws: CocoaError.self) { _ = try await fixture.export(using: exporter) }

        #expect(renderer.started == false)
        #expect(exporter.isExporting == false)
        #expect(exporter.progress == 0)
        #expect(exporter.errorMessage == readError.localizedDescription)
        try fixture.expectOnlyOriginalRemains()
    }

    @Test func sourceEditsDuringArtworkReadKeepCopiedAndEmbeddedMetadataConsistent() async throws {
        let artwork = Data([1, 2, 3])
        let probe = ExportArtworkReadProbe(data: artwork)
        let fixture = try TransformedExportFixture(artworkLoader: LibraryArtworkLoader(read: probe.read))
        defer { fixture.remove() }
        fixture.source.artworkData = artwork
        fixture.source.lyricsRaw = "Original lyrics"
        try fixture.context.save()
        let renderer = ControlledExportRenderer(behavior: .finishImmediately)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task { try await fixture.export(using: exporter).id }
        defer { task.cancel(); probe.release() }

        try await probe.waitUntilReading()
        #expect(renderer.started == false)
        fixture.source.artist = "Edited Artist"
        fixture.source.lyricsRaw = "Edited lyrics"
        try fixture.context.save()
        probe.release()
        let copyID = try await task.value
        let copy = try #require(fixture.context.fetch(FetchDescriptor<MediaItem>()).first { $0.id == copyID })
        let embedded = try AdditionalAudioMetadata.read(
            from: fixture.mediaDirectory.appendingPathComponent(copy.fileName)
        )

        #expect(copy.artist == "Artist")
        #expect(copy.lyricsRaw == "Original lyrics")
        #expect(embedded.values.artist == "Artist")
        #expect(embedded.lyrics == "Original lyrics")
        #expect(embedded.artworkData == artwork)
        #expect(copy.artworkData == artwork)
        #expect(fixture.source.artist == "Edited Artist")
        #expect(fixture.source.lyricsRaw == "Edited lyrics")
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 2)
        #expect(try fixture.renderedFiles().isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationOrDeletionDuringArtworkReadPreventsRendering(deleteSource: Bool) async throws {
        let artwork = Data([1, 2, 3])
        let probe = ExportArtworkReadProbe(data: artwork)
        let fixture = try TransformedExportFixture(artworkLoader: LibraryArtworkLoader(read: probe.read))
        defer { fixture.remove() }
        fixture.source.artworkData = artwork
        try fixture.context.save()
        let renderer = ControlledExportRenderer(behavior: .finishImmediately)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task { _ = try await fixture.export(using: exporter) }
        defer { task.cancel(); probe.release() }

        try await probe.waitUntilReading()
        var fileRemoval: Task<Void, Never>?
        if deleteSource {
            fileRemoval = fixture.service.delete(fixture.source, from: fixture.context)
        } else {
            task.cancel()
        }
        probe.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(renderer.started == false)
        #expect(exporter.isExporting == false)
        #expect(exporter.progress == 0)
        #expect(exporter.errorMessage == nil)
        #expect(try fixture.renderedFiles().isEmpty)
        if deleteSource {
            #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
            await fileRemoval?.value
            #expect(try fixture.mediaFiles().isEmpty)
        } else {
            try fixture.expectOnlyOriginalRemains()
        }
    }
}

nonisolated private final class ExportArtworkReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let data: Data
    private var started = false

    init(data: Data) {
        self.data = data
    }

    func read(_ artworkID: UUID, _ container: ModelContainer) throws -> Data? {
        lock.withLock { started = true }
        guard gate.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        return data
    }

    func release() { gate.signal() }

    func waitUntilReading() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while lock.withLock({ started }) == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(lock.withLock { started }, "The export artwork reader did not start before the deadline")
    }
}

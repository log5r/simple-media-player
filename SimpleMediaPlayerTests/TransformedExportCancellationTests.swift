import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct TransformedExportCancellationTests {
    @Test func cancellationReachesRunningRendererAndRemovesPartialOutput() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let renderer = ControlledExportRenderer(behavior: .observeCancellation)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task { try await fixture.export(using: exporter) }
        defer { task.cancel(); renderer.release() }

        try await renderer.waitUntilStarted()
        #expect(try fixture.renderedFiles().count == 1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled export should throw CancellationError")
        } catch is CancellationError {
        }

        #expect(renderer.observedCancellation)
        #expect(exporter.isExporting == false)
        #expect(exporter.progress == 0)
        #expect(exporter.errorMessage == nil)
        try fixture.expectOnlyOriginalRemains()

        renderer.reportProgress(1)
        try await Task.sleep(for: .milliseconds(10))
        #expect(exporter.progress == 0)
    }

    @Test func cancellationBeforeExportDoesNotStartRenderer() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let renderer = ControlledExportRenderer(behavior: .finishImmediately)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task { try await fixture.export(using: exporter) }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("An already cancelled export should throw CancellationError")
        } catch is CancellationError {
        }

        #expect(renderer.started == false)
        #expect(exporter.isExporting == false)
        #expect(exporter.errorMessage == nil)
        try fixture.expectOnlyOriginalRemains()
    }

    @Test func rendererReturningAfterCancellationCannotRegisterItsOutput() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let renderer = ControlledExportRenderer(behavior: .ignoreCancellation)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task { try await fixture.export(using: exporter) }
        defer { task.cancel(); renderer.release() }

        try await renderer.waitUntilStarted()
        task.cancel()
        renderer.release()
        do {
            _ = try await task.value
            Issue.record("Cancellation should prevent registration even if rendering returns successfully")
        } catch is CancellationError {
        }

        #expect(renderer.finished)
        #expect(exporter.progress == 0)
        #expect(exporter.errorMessage == nil)
        try fixture.expectOnlyOriginalRemains()
    }

    @Test func deletionDuringRenderingPreventsLateCopyRegistration() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let renderer = ControlledExportRenderer(behavior: .ignoreCancellation)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task { _ = try await fixture.export(using: exporter) }
        defer { task.cancel(); renderer.release() }

        try await renderer.waitUntilStarted()
        fixture.service.delete(fixture.source, from: fixture.context)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path) == false)

        // Deleting the library source is independent of cancelling the export task.
        renderer.release()
        do {
            _ = try await task.value
            Issue.record("A deleted source must not register a copy when rendering finishes")
        } catch is CancellationError {
        }

        #expect(renderer.finished)
        #expect(exporter.isExporting == false)
        #expect(exporter.progress == 0)
        #expect(exporter.errorMessage == nil)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
        #expect(try fixture.mediaFiles().isEmpty)
        #expect(try fixture.renderedFiles().isEmpty)
    }

    @Test func sourceEditsDuringRenderingKeepCopiedAndEmbeddedMetadataConsistent() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let renderer = ControlledExportRenderer(behavior: .ignoreCancellation)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task {
            let copy = try await fixture.export(using: exporter)
            return (artist: copy.artist, fileName: copy.fileName)
        }
        defer { task.cancel(); renderer.release() }

        try await renderer.waitUntilStarted()
        fixture.source.artist = "Edited Artist"
        try fixture.context.save()
        renderer.release()
        let item = try await task.value
        let outputURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        let embedded = try AdditionalAudioMetadata.read(from: outputURL)

        #expect(item.artist == "Artist")
        #expect(embedded.values.artist == "Artist")
        #expect(fixture.source.artist == "Edited Artist")
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 2)
        #expect(try fixture.renderedFiles().isEmpty)
    }

    @Test func cancelledRegistrationKeepsRenderedSourceAndDoesNotInsertItem() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let renderedURL = fixture.renderDirectory.appendingPathComponent("already-rendered.wav")
        let renderedData = Data("rendered audio".utf8)
        try renderedData.write(to: renderedURL)
        let task = Task {
            try await fixture.service.registerTransformedCopy(
                of: fixture.source,
                renderedFileURL: renderedURL,
                title: "Rendered",
                duration: 1,
                in: fixture.context
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("An already cancelled registration should throw CancellationError")
        } catch is CancellationError {
        }

        #expect(try Data(contentsOf: renderedURL) == renderedData)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 1)
        #expect(try fixture.mediaFiles() == [fixture.source.fileName])
        #expect(try Data(contentsOf: fixture.sourceURL) == fixture.originalData)
    }

    @Test func successfulExportRegistersAudioAndRemovesTemporaryOutput() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let renderer = ControlledExportRenderer(behavior: .finishImmediately)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)

        let item = try await fixture.export(using: exporter)

        #expect(renderer.finished)
        #expect(item.title == "Rendered")
        #expect(item.artist == fixture.source.artist)
        #expect(item.duration == 0.01)
        #expect(exporter.isExporting == false)
        #expect(exporter.progress == 1)
        #expect(exporter.errorMessage == nil)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 2)
        #expect(try fixture.renderedFiles().isEmpty)
        let outputURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        let output = try AVAudioFile(forReading: outputURL)
        #expect(output.length == 441)
        #expect(try Data(contentsOf: fixture.sourceURL) == fixture.originalData)
    }

    @Test func realRendererFinishesAACBeforeMetadataAndRegistration() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let samples = try #require(buffer.floatChannelData?.pointee)
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = sin(Float(frame) * 0.05) * 0.1
        }
        do {
            let file = try AVAudioFile(forWriting: fixture.sourceURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let sourceData = try Data(contentsOf: fixture.sourceURL)
        let exporter = TransformedTrackExporter(temporaryDirectory: fixture.renderDirectory)
        let item = try await exporter.export(
            item: fixture.source,
            title: "Rendered AAC",
            format: .aac,
            pitchSemitones: 0,
            rate: 1,
            libraryService: fixture.service,
            context: fixture.context
        )

        let outputURL = fixture.mediaDirectory.appendingPathComponent(item.fileName)
        #expect(try AVAudioFile(forReading: outputURL).length > 0)
        #expect(try MP4TitleReader.title(in: outputURL) == "Rendered AAC")
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 2)
        #expect(try fixture.renderedFiles().isEmpty)
        #expect(try Data(contentsOf: fixture.sourceURL) == sourceData)
        #expect(exporter.progress == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func artworkSnapshotMatchesFileAndLibraryAfterSourceEdit(hadArtwork: Bool, removeArtwork: Bool) async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let initialArtwork = hadArtwork ? Data([1, 2, 3]) : nil
        fixture.source.artworkData = initialArtwork
        try fixture.context.save()
        let renderer = ControlledExportRenderer(behavior: .ignoreCancellation)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task { try await fixture.export(using: exporter) }
        defer { task.cancel(); renderer.release() }
        try await renderer.waitUntilStarted()

        let editedArtwork = removeArtwork ? nil : Data([4, 5, 6])
        fixture.source.artworkData = editedArtwork
        try fixture.context.save()
        renderer.release()
        let copy = try await task.value

        let outputURL = fixture.mediaDirectory.appendingPathComponent(copy.fileName)
        #expect(try AdditionalAudioMetadata.read(from: outputURL).artworkData == initialArtwork)
        #expect(try await fixture.service.libraryArtwork(for: copy) == initialArtwork)
        #expect(try await fixture.service.libraryArtwork(for: fixture.source) == editedArtwork)
        #expect(copy.artworkID == nil || copy.artworkID != fixture.source.artworkID)
        #expect(try fixture.renderedFiles().isEmpty)
    }

    @Test(arguments: [false, true])
    func deletedSourceCannotRegisterRenderedSnapshot(hadArtwork: Bool) async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        fixture.source.artworkData = hadArtwork ? Data([1, 2, 3]) : nil
        try fixture.context.save()
        let renderer = ControlledExportRenderer(behavior: .ignoreCancellation)
        let exporter = TransformedTrackExporter(renderer: renderer, temporaryDirectory: fixture.renderDirectory)
        let task = Task { try await fixture.export(using: exporter) }
        defer { task.cancel(); renderer.release() }
        try await renderer.waitUntilStarted()

        fixture.service.delete(fixture.source, from: fixture.context)
        renderer.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
        #expect(try fixture.mediaFiles().isEmpty)
        #expect(try fixture.renderedFiles().isEmpty)
        #expect(exporter.isExporting == false)
        #expect(exporter.progress == 0)
        #expect(exporter.errorMessage == nil)
    }
}

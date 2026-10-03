import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
final class TransformedExportFixture {
    let directory: URL
    let mediaDirectory: URL
    let renderDirectory: URL
    let sourceURL: URL
    let originalData = Data("original audio".utf8)
    let container: ModelContainer
    let context: ModelContext
    let service: LibraryService
    let source: MediaItem

    init(artworkLoader: LibraryArtworkLoader = .shared) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransformedExportTests-\(UUID().uuidString)", isDirectory: true)
        mediaDirectory = directory.appendingPathComponent("Media", isDirectory: true)
        renderDirectory = directory.appendingPathComponent("Rendering", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
        sourceURL = mediaDirectory.appendingPathComponent("source.wav")
        try originalData.write(to: sourceURL)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = container.mainContext
        service = LibraryService(mediaDirectoryURL: mediaDirectory, artworkLoader: artworkLoader)
        source = MediaItem(
            title: "Original",
            artist: "Artist",
            duration: 1,
            isVideo: false,
            bookmarkData: Data([0xFF]),
            fileName: sourceURL.lastPathComponent
        )
        context.insert(source)
        try context.save()
    }

    func export(using exporter: TransformedTrackExporter) async throws -> MediaItem {
        try await exporter.export(
            item: source,
            title: "Rendered",
            format: .wav,
            pitchSemitones: 0,
            rate: 1,
            libraryService: service,
            context: context
        )
    }

    func mediaFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: mediaDirectory.path).sorted()
    }

    func renderedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: renderDirectory.path)
    }

    func expectOnlyOriginalRemains() throws {
        #expect(try context.fetchCount(FetchDescriptor<MediaItem>()) == 1)
        #expect(try mediaFiles() == [source.fileName])
        #expect(try renderedFiles().isEmpty)
        #expect(try Data(contentsOf: sourceURL) == originalData)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

nonisolated final class ControlledExportRenderer: TransformedAudioRendering, @unchecked Sendable {
    enum Behavior {
        case observeCancellation
        case ignoreCancellation
        case finishImmediately
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var didStart = false
    private var didFinish = false
    private var didObserveCancellation = false
    private var isReleased = false
    private var progressCallback: (@Sendable (Double) -> Void)?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var started: Bool { lock.withLock { didStart } }
    var finished: Bool { lock.withLock { didFinish } }
    var observedCancellation: Bool { lock.withLock { didObserveCancellation } }

    func release() {
        lock.withLock { isReleased = true }
    }

    func reportProgress(_ value: Double) {
        let callback = lock.withLock { progressCallback }
        callback?(value)
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while started == false && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(started, "The export renderer did not start before the deadline")
    }

    func render(
        sourceURL: URL,
        pitchCents: Float,
        rate: Float,
        maxSampleRate: Double?,
        makeEncoder: (AVAudioFormat) throws -> any AudioFileEncoding,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> TransformedAudioRenderer.Result {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441))
        buffer.frameLength = 441
        let samples = try #require(buffer.floatChannelData?.pointee)
        samples.update(repeating: 0, count: 441)
        let encoder = try makeEncoder(format)
        defer { encoder.cancel() }
        try encoder.encode(buffer: buffer)
        lock.withLock {
            didStart = true
            progressCallback = progress
        }
        progress(0.5)

        if behavior != .finishImmediately {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while lock.withLock({ isReleased }) == false {
                if behavior == .observeCancellation && Task.isCancelled {
                    lock.withLock { didObserveCancellation = true }
                    throw CancellationError()
                }
                guard ContinuousClock.now < deadline else {
                    throw TransformedAudioExportError.renderFailed(
                        "The test renderer was not released before the deadline"
                    )
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        try encoder.finish()
        lock.withLock { didFinish = true }
        progress(1)
        return TransformedAudioRenderer.Result(duration: 0.01)
    }
}

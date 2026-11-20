import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct MusicLibraryTrackExporterLifecycleTests {
    @Test func incompatiblePassthroughFallsBackToPlayableAAC() async throws {
        let fixture = try MusicExportLifecycleFixture()
        defer { fixture.remove() }
        let source = try writeAudio(named: "source.wav", in: fixture.directory, formatID: kAudioFormatLinearPCM)
        let output = try await MusicLibraryTrackExporter.$passthroughFileTypes.withValue([]) {
            try await MusicLibraryTrackExporter.export(assetURL: source, to: fixture.directory, baseName: "fallback")
        }
        #expect(output.format == .m4a)
        #expect(output.isTranscoded)
        #expect(output.url.lastPathComponent == "fallback.m4a")
        #expect(abs(output.duration - 1) < 0.01)
        let file = try AVAudioFile(forReading: output.url)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(file.length == 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let rms = sqrt((0..<Int(buffer.frameLength)).reduce(0.0) { $0 + pow(Double(samples[$1]), 2) }
            / Double(buffer.frameLength))
        #expect(rms > 0.1)
    }

    @Test func cancellingAfterWritingAnMPEGPacketRemovesPartialOutput() async throws {
        let fixture = try MusicExportLifecycleFixture()
        defer { fixture.remove() }
        let source = try #require(Bundle(for: MusicLibraryTestBundleToken.self).url(
            forResource: "music-library-source", withExtension: "mp3"
        ))
        let probe = ExportCancellationProbe(cancelAt: .mpegPacketWritten)
        let task = Task {
            try await MusicLibraryTrackExporter.$observeExport.withValue({ probe.observe($0, at: $1) }, operation: {
                try await MusicLibraryTrackExporter.export(assetURL: source, to: fixture.directory, baseName: "partial")
            })
        }
        probe.installCancellation { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.observedEvents.contains(.mpegPacketWritten))
        #expect(probe.bytesBeforeCancellation > 0)
        #expect(probe.observedEvents.contains(.validationStarted) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test func cancellingAnExportingAACSessionCallsCancelAndRemovesItsOutput() async throws {
        let fixture = try MusicExportLifecycleFixture()
        defer { fixture.remove() }
        // Observe AVFoundation's actual exporting state. A longer source keeps enough work in
        // flight to cancel it; no sleep guesses when the session might have started.
        let source = try writeAudio(
            named: "source.wav", in: fixture.directory, formatID: kAudioFormatLinearPCM, seconds: 60
        )
        let probe = ExportCancellationProbe(cancelAt: .sessionExporting)
        let task = Task {
            try await MusicLibraryTrackExporter.$passthroughFileTypes.withValue([]) {
                try await MusicLibraryTrackExporter.$observeExport.withValue({ probe.observe($0, at: $1) }, operation: {
                    try await MusicLibraryTrackExporter.export(
                        assetURL: source, to: fixture.directory, baseName: "cancelled"
                    )
                })
            }
        }
        probe.installCancellation { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.observedEvents.contains(.sessionExporting))
        #expect(probe.observedEvents.contains(.sessionCancelled))
        #expect(probe.observedEvents.contains(.validationStarted) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["source.wav"])
    }

    /// A cancelled session can create its output a few milliseconds after `export(to:as:)` has thrown, which
    /// cannot be forced here. This checks the structure that keeps such a file out of the destination: the
    /// session writes into its own directory, and that directory is gone once the export has returned.
    @Test func cancelledSessionWritesOutsideTheDestinationAndRemovesItsScratchDirectory() async throws {
        let fixture = try MusicExportLifecycleFixture()
        defer { fixture.remove() }
        let source = try writeAudio(
            named: "source.wav", in: fixture.directory, formatID: kAudioFormatLinearPCM, seconds: 60
        )
        let probe = ExportCancellationProbe(cancelAt: .sessionExporting, listing: fixture.directory)
        let task = Task {
            try await MusicLibraryTrackExporter.$passthroughFileTypes.withValue([]) {
                try await MusicLibraryTrackExporter.$observeExport.withValue({ probe.observe($0, at: $1) }, operation: {
                    try await MusicLibraryTrackExporter.export(
                        assetURL: source, to: fixture.directory, baseName: "scratch"
                    )
                })
            }
        }
        probe.installCancellation { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        let exporting = try #require(probe.firstObservation(of: .sessionExporting))
        #expect(exporting.listing == ["source.wav"])
        #expect(exporting.url.lastPathComponent == "scratch.m4a")
        #expect(exporting.url.pathComponents.contains(fixture.directory.lastPathComponent) == false)
        #expect(probe.firstObservation(of: .sessionCancelled)?.url == exporting.url)
        #expect(FileManager.default.fileExists(atPath: exporting.url.deletingLastPathComponent().path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["source.wav"])
    }

    @Test func finishedSessionOutputIsMovedIntoTheDestinationAndItsScratchDirectoryRemoved() async throws {
        let fixture = try MusicExportLifecycleFixture()
        defer { fixture.remove() }
        // Long enough for the session to report its exporting state before it finishes.
        let source = try writeAudio(
            named: "source.wav", in: fixture.directory, formatID: kAudioFormatLinearPCM, seconds: 60
        )
        let probe = ExportCancellationProbe(cancelAt: nil, listing: fixture.directory)
        let output = try await MusicLibraryTrackExporter.$passthroughFileTypes.withValue([]) {
            try await MusicLibraryTrackExporter.$observeExport.withValue({ probe.observe($0, at: $1) }, operation: {
                try await MusicLibraryTrackExporter.export(assetURL: source, to: fixture.directory, baseName: "moved")
            })
        }
        let exporting = try #require(probe.firstObservation(of: .sessionExporting))
        #expect(exporting.listing == ["source.wav"])
        #expect(exporting.url.lastPathComponent == "moved.m4a")
        #expect(exporting.url.pathComponents.contains(fixture.directory.lastPathComponent) == false)
        #expect(FileManager.default.fileExists(atPath: exporting.url.deletingLastPathComponent().path) == false)
        #expect(output.url.lastPathComponent == "moved.m4a")
        #expect(abs(output.duration - 60) < 0.1)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: fixture.directory.path))
            == ["source.wav", "moved.m4a"])
    }

    @Test func cancellationWhileOutputValidationIsBlockedReturnsBeforeTheOpenFinishes() async throws {
        let fixture = try MusicExportLifecycleFixture()
        defer { fixture.remove() }
        let source = try writeAudio(named: "source.wav", in: fixture.directory, formatID: kAudioFormatLinearPCM)
        let gate = ExportValidationGate()
        let task = Task {
            try await MusicLibraryTrackExporter.$observeExport.withValue({ gate.observe($0, at: $1) }, operation: {
                try await MusicLibraryTrackExporter.export(
                    assetURL: source, to: fixture.directory, baseName: "validated"
                )
            })
        }
        defer { task.cancel(); gate.release() }
        try #require(await gate.started.waitAsync(timeout: .now() + 5) == .success)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("validated.wav").path))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(gate.hasFinished == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["source.wav"])
        gate.release()
        try #require(await gate.finished.waitAsync(timeout: .now() + 5) == .success)
        #expect(gate.hasFinished)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["source.wav"])
    }
}

nonisolated private struct MusicExportLifecycleFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

nonisolated private final class ExportCancellationProbe: @unchecked Sendable {
    struct Observation {
        let event: MusicLibraryTrackExporter.Event
        let url: URL
        /// The sorted contents of the listed directory when the event was reported.
        let listing: [String]?
    }

    private let lock = NSLock()
    private let cancelAt: MusicLibraryTrackExporter.Event?
    private let listedDirectory: URL?
    private var cancellation: (@Sendable () -> Void)?
    private var requested = false
    private var events: [MusicLibraryTrackExporter.Event] = []
    private var observations: [Observation] = []
    private var bytes = 0
    var observedEvents: [MusicLibraryTrackExporter.Event] { lock.withLock { events } }
    var bytesBeforeCancellation: Int { lock.withLock { bytes } }

    /// With `cancelAt` nil, the probe only records what it observes.
    init(cancelAt: MusicLibraryTrackExporter.Event?, listing directory: URL? = nil) {
        self.cancelAt = cancelAt
        listedDirectory = directory
    }

    func firstObservation(of event: MusicLibraryTrackExporter.Event) -> Observation? {
        lock.withLock { observations.first { $0.event == event } }
    }

    func installCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock { self.cancellation = cancellation; return requested }
        if shouldCancel { cancellation() }
    }

    func observe(_ event: MusicLibraryTrackExporter.Event, at url: URL) {
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let listing = listedDirectory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path).sorted() }
        let cancel = lock.withLock { () -> (@Sendable () -> Void)? in
            events.append(event)
            observations.append(Observation(event: event, url: url, listing: listing))
            guard event == cancelAt, !requested else { return nil }
            bytes = byteCount
            requested = true
            return cancellation
        }
        cancel?()
    }
}

nonisolated private final class ExportValidationGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didFinish = false
    var hasFinished: Bool { lock.withLock { didFinish } }

    func observe(_ event: MusicLibraryTrackExporter.Event, at _: URL) {
        if event == .validationStarted {
            started.signal()
            if gate.wait(timeout: .now() + 10) != .success {
                Issue.record("Output validation must stay held until the cancelled caller has returned.")
            }
        } else if event == .validationFinished {
            lock.withLock { didFinish = true }
            finished.signal()
        }
    }

    func release() { gate.signal() }
}

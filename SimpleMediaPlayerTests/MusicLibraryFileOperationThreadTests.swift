import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

/// The Music library export and its callers run on the main actor; their file removals and directory
/// creations must not.
@MainActor
struct MusicLibraryFileOperationThreadTests {
    @Test func exportRemovesAStaleOutputOffTheMainThreadBeforeWriting() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeAudio(named: "source.wav", in: directory, formatID: kAudioFormatLinearPCM)
        let stale = directory.appendingPathComponent("out.wav")
        try Data("stale".utf8).write(to: stale)
        let recorder = FileOperationRecorder()

        let output = try await MusicLibraryTrackExporter.$observeExport.withValue(recorder.record, operation: {
            try await MusicLibraryTrackExporter.export(assetURL: source, to: directory, baseName: "out")
        })

        #expect(output.url.lastPathComponent == "out.wav")
        #expect(abs(output.duration - 1) < 0.01)
        let removals = recorder.calls(of: .staleOutputRemoved)
        #expect(removals.map(\.url.lastPathComponent) == ["out.wav"])
        #expect(removals.map(\.isMainThread) == [false])
        #expect(recorder.calls(of: .failedOutputRemoved).isEmpty)
    }

    @Test func cancelledExportRemovesItsPartialOutputOffTheMainThread() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle(for: MusicLibraryTestBundleToken.self).url(
            forResource: "music-library-source", withExtension: "mp3"
        ))
        let recorder = FileOperationRecorder(cancelAt: .mpegPacketWritten)
        let task = Task {
            try await MusicLibraryTrackExporter.$observeExport.withValue(recorder.record, operation: {
                try await MusicLibraryTrackExporter.export(assetURL: source, to: directory, baseName: "partial")
            })
        }
        recorder.installCancellation { task.cancel() }

        await #expect(throws: CancellationError.self) { try await task.value }

        let removals = recorder.calls(of: .failedOutputRemoved)
        #expect(removals.map(\.url.lastPathComponent) == ["partial.mp3"])
        #expect(removals.map(\.isMainThread) == [false])
        // The removal is awaited, so nothing is left once the cancelled export has returned.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func importCreatesItsStagingDirectoryOffTheMainThread() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 40, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let recorder = DirectoryCreationRecorder()

        let result = await MusicLibraryTemporaryFiles.$observeDirectoryCreation.withValue(recorder.record, operation: {
            await fixture.service.importMusicLibraryTracks([track], into: fixture.context, existingItems: [])
        })

        #expect(result?.importedCount == 1)
        let creations = recorder.creations
        #expect(creations.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["ImportStaging"])
        #expect(creations.map(\.isMainThread) == [false])
        #expect(await fixture.temporaryFilesAreGone())
    }

    @Test func playbackCreatesItsSessionDirectoryOffTheMainThread() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 41, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let recorder = DirectoryCreationRecorder()

        let outcome = await MusicLibraryTemporaryFiles.$observeDirectoryCreation.withValue(recorder.record, operation: {
            await fixture.service.prepareMusicLibraryPlayback(of: track)
        })

        guard case let .ready(session) = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }
        let creations = recorder.creations
        #expect(creations.map(\.url) == [session.directory])
        #expect(creations.map(\.isMainThread) == [false])
        session.end()
        await session.awaitCleanup()
    }

    /// The panel stays responsive while the creation is held, and a cancellation that arrives before the
    /// import task exists still removes the new directory and imports nothing.
    @Test func cancellingTheImportWhileItsDirectoryIsCreatedImportsNothing() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 42, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let gate = DirectoryCreationGate()
        defer { gate.release() }
        let exportEvents = FileOperationRecorder()
        let task = Task {
            await MusicLibraryTrackExporter.$observeExport.withValue(exportEvents.record, operation: {
                await MusicLibraryTemporaryFiles.$observeDirectoryCreation.withValue(gate.hold, operation: {
                    await fixture.service.importMusicLibraryTracks([track], into: fixture.context, existingItems: [])
                })
            })
        }
        try #require(await gate.started.waitAsync(timeout: .now() + 5) == .success)
        let directory = try #require(gate.directory)
        #expect(FileManager.default.fileExists(atPath: directory.path))

        fixture.service.cancelMusicLibraryPreparation()
        gate.release()
        let result = await task.value

        #expect(result?.wasCancelled == true)
        #expect(result?.importedCount == 0)
        // Nothing is exported for a preparation that ended before its task was attached.
        #expect(exportEvents.isEmpty)
        #expect(try fixture.items().isEmpty)
        #expect(try fixture.managedFiles().isEmpty)
        #expect(await directoryIsRemoved(directory))
    }

    @Test func replacingTheImportWhileItsDirectoryIsCreatedReportsNothing() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 43, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let gate = DirectoryCreationGate()
        defer { gate.release() }
        let exportEvents = FileOperationRecorder()
        let task = Task {
            await MusicLibraryTrackExporter.$observeExport.withValue(exportEvents.record, operation: {
                await MusicLibraryTemporaryFiles.$observeDirectoryCreation.withValue(gate.hold, operation: {
                    await fixture.service.importMusicLibraryTracks([track], into: fixture.context, existingItems: [])
                })
            })
        }
        try #require(await gate.started.waitAsync(timeout: .now() + 5) == .success)
        let directory = try #require(gate.directory)

        let newer = fixture.service.beginMusicLibraryPreparation(.playback, totalCount: 1)
        gate.release()
        let result = await task.value

        #expect(result == nil)
        #expect(fixture.service.musicLibraryPreparation === newer)
        #expect(exportEvents.isEmpty)
        #expect(try fixture.items().isEmpty)
        #expect(await directoryIsRemoved(directory))
        fixture.service.cancelMusicLibraryPreparation()
    }

    @Test func cancellingPlaybackWhileItsDirectoryIsCreatedRemovesIt() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 44, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let gate = DirectoryCreationGate()
        defer { gate.release() }
        let exportEvents = FileOperationRecorder()
        let task = Task {
            await MusicLibraryTrackExporter.$observeExport.withValue(exportEvents.record, operation: {
                await MusicLibraryTemporaryFiles.$observeDirectoryCreation.withValue(gate.hold, operation: {
                    await fixture.service.prepareMusicLibraryPlayback(of: track)
                })
            })
        }
        try #require(await gate.started.waitAsync(timeout: .now() + 5) == .success)
        let directory = try #require(gate.directory)

        fixture.service.cancelMusicLibraryPreparation()
        gate.release()
        let outcome = await task.value

        guard case .cancelled = outcome else {
            Issue.record("Expected cancellation, got \(outcome)")
            return
        }
        #expect(exportEvents.isEmpty)
        #expect(await directoryIsRemoved(directory))
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-file-operations-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Abandoned directories are removed by a detached task, so the check waits briefly for it.
    private func directoryIsRemoved(_ directory: URL) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.path) == false { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

/// Records export events with the thread they ran on, and can cancel the export at one of them.
nonisolated private final class FileOperationRecorder: @unchecked Sendable {
    struct Call {
        let event: MusicLibraryTrackExporter.Event
        let url: URL
        let isMainThread: Bool
    }

    private let lock = NSLock()
    private let cancelAt: MusicLibraryTrackExporter.Event?
    private var cancellation: (@Sendable () -> Void)?
    private var requested = false
    private var recorded: [Call] = []

    init(cancelAt: MusicLibraryTrackExporter.Event? = nil) {
        self.cancelAt = cancelAt
    }

    var isEmpty: Bool { lock.withLock { recorded.isEmpty } }

    func calls(of event: MusicLibraryTrackExporter.Event) -> [Call] {
        lock.withLock { recorded.filter { $0.event == event } }
    }

    func installCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock { self.cancellation = cancellation; return requested }
        if shouldCancel { cancellation() }
    }

    func record(_ event: MusicLibraryTrackExporter.Event, at url: URL) {
        let call = Call(event: event, url: url, isMainThread: Thread.isMainThread)
        let cancel = lock.withLock { () -> (@Sendable () -> Void)? in
            recorded.append(call)
            guard event == cancelAt, !requested else { return nil }
            requested = true
            return cancellation
        }
        cancel?()
    }
}

nonisolated private final class DirectoryCreationRecorder: @unchecked Sendable {
    struct Creation {
        let url: URL
        let isMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Creation] = []
    var creations: [Creation] { lock.withLock { recorded } }

    func record(_ url: URL) {
        let creation = Creation(url: url, isMainThread: Thread.isMainThread)
        lock.withLock { recorded.append(creation) }
    }
}

/// Holds the file system queue after a directory has been created, until the test releases it.
nonisolated private final class DirectoryCreationGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var created: URL?
    var directory: URL? { lock.withLock { created } }

    func hold(_ url: URL) {
        lock.withLock { created = url }
        started.signal()
        if gate.wait(timeout: .now() + 10) != .success {
            Issue.record("The directory creation must stay held until the test releases it.")
        }
    }

    /// Safe to call more than once; extra signals are never waited on.
    func release() { gate.signal() }
}

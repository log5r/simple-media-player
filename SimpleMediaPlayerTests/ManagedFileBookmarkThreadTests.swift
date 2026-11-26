import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

/// Transformed exports and Music library playback bookmark the files they write. Both are driven from the main
/// actor, so the bookmark must run elsewhere, and a result that arrives after cancellation must not be applied.
@MainActor
struct ManagedFileBookmarkThreadTests {
    @Test func transformedCopyIsBookmarkedOffTheMainThread() async throws {
        let probe = BookmarkProbe()
        let fixture = try TransformedExportFixture(importFileOperations: probe.operations)
        defer { fixture.remove() }
        let renderedURL = try writeRendered(in: fixture)

        let item = try await fixture.service.registerTransformedCopy(
            of: fixture.source, renderedFileURL: renderedURL, title: "Rendered", duration: 1, in: fixture.context
        )

        let calls = probe.calls
        #expect(calls.map(\.isMainThread) == [false])
        #expect(calls.map(\.url.lastPathComponent) == [item.fileName])
        #expect(item.bookmarkData.isEmpty == false)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 2)
    }

    /// The caller returns without waiting for the held bookmark, and the copy is removed before it does.
    @Test func cancellingTheTransformedRegistrationDuringTheBookmarkRegistersNothing() async throws {
        let probe = BookmarkProbe(holds: true)
        let fixture = try TransformedExportFixture(importFileOperations: probe.operations)
        defer { fixture.remove() }
        defer { probe.release() }
        let renderedURL = try writeRendered(in: fixture)
        let task = Task {
            _ = try await fixture.service.registerTransformedCopy(
                of: fixture.source, renderedFileURL: renderedURL, title: "Rendered", duration: 1, in: fixture.context
            )
        }
        try #require(await probe.started.waitAsync(timeout: .now() + 5) == .success)
        #expect(try fixture.mediaFiles().count == 2)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(probe.hasFinished == false)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 1)
        #expect(try fixture.mediaFiles() == [fixture.source.fileName])
        #expect(FileManager.default.fileExists(atPath: renderedURL.path))
    }

    @Test func deletingTheSourceDuringTheBookmarkRegistersNothing() async throws {
        let probe = BookmarkProbe(holds: true)
        let fixture = try TransformedExportFixture(importFileOperations: probe.operations)
        defer { fixture.remove() }
        defer { probe.release() }
        let renderedURL = try writeRendered(in: fixture)
        let task = Task {
            _ = try await fixture.service.registerTransformedCopy(
                of: fixture.source, renderedFileURL: renderedURL, title: "Rendered", duration: 1, in: fixture.context
            )
        }
        try #require(await probe.started.waitAsync(timeout: .now() + 5) == .success)
        let sourceFileName = fixture.source.fileName

        fixture.context.delete(fixture.source)
        try fixture.context.save()
        probe.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.hasFinished)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
        #expect(try fixture.mediaFiles() == [sourceFileName])
    }

    @Test func musicLibraryPlaybackIsBookmarkedOffTheMainThread() async throws {
        let probe = BookmarkProbe()
        let fixture = try MusicLibraryFixture(importFileOperations: probe.operations)
        defer { fixture.remove() }
        let track = fixture.makeTrack(id: 50, fileName: "song.wav", formatID: kAudioFormatLinearPCM)

        let outcome = await fixture.service.prepareMusicLibraryPlayback(of: track)

        guard case let .ready(session) = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }
        let calls = probe.calls
        #expect(calls.map(\.isMainThread) == [false])
        #expect(calls.map { $0.url.deletingLastPathComponent().standardizedFileURL.path }
            == [session.directory.standardizedFileURL.path])
        #expect(session.items.first?.bookmarkData.isEmpty == false)
        session.end()
        await session.awaitCleanup()
    }

    /// The cancelled preparation reports at once, and the bookmark that finishes later leaves no item or file.
    @Test func cancellingMusicLibraryPlaybackDuringTheBookmarkReturnsWithoutASession() async throws {
        let probe = BookmarkProbe(holds: true)
        let fixture = try MusicLibraryFixture(importFileOperations: probe.operations)
        defer { fixture.remove() }
        defer { probe.release() }
        let track = fixture.makeTrack(id: 51, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let task = Task { await fixture.service.prepareMusicLibraryPlayback(of: track) }
        try #require(await probe.started.waitAsync(timeout: .now() + 5) == .success)

        fixture.service.cancelMusicLibraryPreparation()
        let outcome = await task.value

        guard case .cancelled = outcome else {
            Issue.record("Expected cancellation, got \(outcome)")
            return
        }
        #expect(probe.hasFinished == false)
        #expect(fixture.service.musicLibraryPreparation == nil)
        probe.release()
        try #require(await probe.finished.waitAsync(timeout: .now() + 5) == .success)
        #expect(await fixture.temporaryFilesAreGone())
    }

    /// Bookmarks abandoned by cancelled preparations keep their limiter slots. Once two are held, a third
    /// preparation waits for a slot without starting its bookmark, and its cancellation still returns at once.
    @Test func repeatedlyCancelledPlaybackKeepsAtMostTwoBookmarksRunning() async throws {
        let probe = BookmarkProbe(holds: true)
        let fixture = try MusicLibraryFixture(importFileOperations: probe.operations)
        defer { fixture.remove() }
        defer { probe.release(count: 4) }
        for id: UInt64 in 52...53 {
            let track = fixture.makeTrack(id: id, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
            let task = Task { await fixture.service.prepareMusicLibraryPlayback(of: track) }
            try #require(await probe.started.waitAsync(timeout: .now() + 5) == .success)
            fixture.service.cancelMusicLibraryPreparation()
            let outcome = await task.value
            guard case .cancelled = outcome else {
                Issue.record("Expected cancellation, got \(outcome)")
                return
            }
        }
        #expect(probe.calls.count == 2)

        let validated = DispatchSemaphore(value: 0)
        let third = fixture.makeTrack(id: 54, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let thirdTask = Task {
            await MusicLibraryTrackExporter.$observeExport.withValue({ event, _ in
                if event == .validationFinished { validated.signal() }
            }, operation: {
                await fixture.service.prepareMusicLibraryPlayback(of: third)
            })
        }
        try #require(await validated.waitAsync(timeout: .now() + 5) == .success)
        #expect(await probe.started.waitAsync(timeout: .now() + 0.3) == .timedOut)
        fixture.service.cancelMusicLibraryPreparation()
        let thirdOutcome = await thirdTask.value
        guard case .cancelled = thirdOutcome else {
            Issue.record("Expected cancellation, got \(thirdOutcome)")
            return
        }
        #expect(probe.calls.count == 2)

        // The abandoned bookmarks finish and free their slots; the next preparation's bookmark is let through.
        probe.release(count: 3)
        let fourth = fixture.makeTrack(id: 55, fileName: "song.wav", formatID: kAudioFormatLinearPCM)
        let outcome = await fixture.service.prepareMusicLibraryPlayback(of: fourth)
        guard case let .ready(session) = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }
        #expect(probe.calls.count == 3)
        session.end()
        await session.awaitCleanup()
    }

    private func writeRendered(in fixture: TransformedExportFixture) throws -> URL {
        let url = fixture.renderDirectory.appendingPathComponent("rendered.wav")
        try Data("rendered audio".utf8).write(to: url)
        return url
    }
}

/// Records where each bookmark is made and, when holding, keeps it running until the test releases it.
nonisolated private final class BookmarkProbe: @unchecked Sendable {
    struct Call {
        let url: URL
        let isMainThread: Bool
    }

    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let gate: DispatchSemaphore?
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var didFinish = false

    init(holds: Bool = false) {
        gate = holds ? DispatchSemaphore(value: 0) : nil
    }

    var calls: [Call] { lock.withLock { recorded } }
    var hasFinished: Bool { lock.withLock { didFinish } }

    var operations: ImportFileOperations {
        var operations = ImportFileOperations()
        operations.makeBookmark = { [self] url in try makeBookmark(for: url) }
        return operations
    }

    /// Lets `count` held bookmarks, running or still to come, finish. Extra signals are never waited on.
    func release(count: Int = 1) {
        for _ in 0..<count { gate?.signal() }
    }

    private func makeBookmark(for url: URL) throws -> Data {
        let call = Call(url: url, isMainThread: Thread.isMainThread)
        lock.withLock { recorded.append(call) }
        started.signal()
        if let gate, gate.wait(timeout: .now() + 10) != .success {
            Issue.record("The bookmark must stay held until the test releases it.")
        }
        defer {
            lock.withLock { didFinish = true }
            finished.signal()
        }
        return try ImportFileOperations.managedFileBookmark(for: url)
    }
}

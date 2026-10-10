import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct TransientPlaybackSessionTests {
    @Test func playingASessionQueuesItsItemsWithoutTouchingTheLibrary() throws {
        let session = try makeSession(titles: ["One", "Two"])
        let fixture = makePlayerFixture(urlsByID: urls(for: session))

        fixture.player.play(transientSession: session)

        #expect(fixture.player.currentItem?.id == session.items[0].id)
        #expect(fixture.player.queue.map(\.id) == session.items.map(\.id))
        #expect(fixture.player.isPlayingTransientItem)
        #expect(fixture.player.isTransientItem(session.items[1]))
        #expect(fixture.player.transientSession === session)
        #expect(fixture.audio.loadedURLs == [urls(for: session)[session.items[0].id]])
        #expect(session.items.allSatisfy { $0.modelContext == nil })
        session.end()
    }

    @Test func stoppingAndSkippingKeepTheSession() async throws {
        let session = try makeSession(titles: ["One", "Two"])
        let fixture = makePlayerFixture(urlsByID: urls(for: session))
        fixture.player.play(transientSession: session)

        fixture.player.stop()
        #expect(session.isEnded == false)
        #expect(fixture.player.currentItem?.id == session.items[0].id)

        fixture.player.resume()
        fixture.player.next()
        #expect(fixture.player.currentItem?.id == session.items[1].id)
        #expect(session.isEnded == false)
        #expect(FileManager.default.fileExists(atPath: session.directory.path))

        fixture.player.previous()
        #expect(fixture.player.currentItem?.id == session.items[0].id)
        #expect(fixture.player.transientSession === session)
        session.end()
        await session.awaitCleanup()
    }

    @Test func switchingToALibraryItemEndsTheSession() async throws {
        let session = try makeSession(titles: ["One"])
        let libraryItem = MediaItem(
            title: "Library", duration: 1, isVideo: false, bookmarkData: Data(), fileName: "l.wav"
        )
        var urlsByID = urls(for: session)
        urlsByID[libraryItem.id] = URL(fileURLWithPath: "/tmp/library.wav")
        let fixture = makePlayerFixture(urlsByID: urlsByID)
        fixture.player.play(transientSession: session)

        fixture.player.play(item: libraryItem, in: [libraryItem])
        await waitUntilEnded(session)

        #expect(session.isEnded)
        #expect(fixture.player.transientSession == nil)
        #expect(fixture.player.isPlayingTransientItem == false)
        #expect(FileManager.default.fileExists(atPath: session.directory.path) == false)
    }

    @Test func clearingThePlayerEndsTheSession() async throws {
        let session = try makeSession(titles: ["One"])
        let fixture = makePlayerFixture(urlsByID: urls(for: session))
        fixture.player.play(transientSession: session)

        fixture.player.clearCurrentItem()
        await waitUntilEnded(session)

        #expect(session.isEnded)
        #expect(fixture.player.transientSession == nil)
        #expect(FileManager.default.fileExists(atPath: session.directory.path) == false)
    }

    @Test func aNewSessionEndsThePreviousOneAfterTheSwitch() async throws {
        let first = try makeSession(titles: ["One"])
        let second = try makeSession(titles: ["Two"])
        let fixture = makePlayerFixture(urlsByID: urls(for: first).merging(urls(for: second)) { $1 })
        fixture.player.play(transientSession: first)

        fixture.player.play(transientSession: second)
        await waitUntilEnded(first)

        #expect(first.isEnded)
        #expect(second.isEnded == false)
        #expect(fixture.player.transientSession === second)
        #expect(fixture.player.currentItem?.id == second.items[0].id)
        #expect(fixture.audio.loadedURLs.count == 2)
        second.end()
        await second.awaitCleanup()
    }

    @Test func unresolvableTransientItemEndsTheSession() async throws {
        let session = try makeSession(titles: ["One"])
        let fixture = makePlayerFixture(urlsByID: [:])

        fixture.player.play(transientSession: session)
        await waitUntilEnded(session)

        #expect(session.isEnded)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.player.transientSession == nil)
        #expect(fixture.player.errorMessage != nil)
    }

    @Test func pauseAndResumeAdvanceTheTransportGenerationButNotThePlaybackGeneration() throws {
        let session = try makeSession(titles: ["One"])
        let fixture = makePlayerFixture(urlsByID: urls(for: session))
        fixture.player.play(transientSession: session)
        let playback = fixture.player.playbackGeneration
        let transport = fixture.player.transportGeneration

        fixture.player.pause()
        fixture.player.resume()

        #expect(fixture.player.playbackGeneration == playback)
        #expect(fixture.player.transportGeneration == transport &+ 2)
        fixture.player.stop()
        #expect(fixture.player.transportGeneration == transport &+ 3)
        session.end()
    }

    @Test func endingTheSessionRemovesItsAnalysisCacheEntries() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransientPlaybackSessionTests-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let session = try makeSession(titles: ["One"], analysisCacheDirectory: cacheDirectory)
        let fileURL = session.directory.appendingPathComponent("One.wav")
        try Data("audio".utf8).write(to: fileURL)
        let entry = try #require(MusicAnalysisCache.entryURL(for: fileURL, in: cacheDirectory))
        try Data("{}".utf8).write(to: entry)
        let unrelated = cacheDirectory.appendingPathComponent("unrelated.json")
        try Data("{}".utf8).write(to: unrelated)

        session.end()
        await session.awaitCleanup()

        #expect(FileManager.default.fileExists(atPath: entry.path) == false)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: session.directory.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func endingWaitsForTheCancelledAnalysisToFinish() async throws {
        let gate = BlockingAnalysis()
        // Ignores cancellation, like a cache write that has already started.
        let analysis = MusicAnalysisController(analyze: { _ in await gate.analyze() })
        let session = try makeSession(titles: ["One"])
        let fixture = makePlayerFixture(urlsByID: urls(for: session), musicAnalysis: analysis)
        fixture.player.play(transientSession: session)
        await gate.waitUntilStarted()

        fixture.player.clearCurrentItem()
        #expect(fixture.player.transientSession == nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(session.isEnded == false)
        #expect(FileManager.default.fileExists(atPath: session.directory.path))

        await gate.finish()
        await waitUntilEnded(session)
        #expect(session.isEnded)
        #expect(FileManager.default.fileExists(atPath: session.directory.path) == false)
    }

    /// The player ends a released session only after the cancelled analysis task finishes.
    private func waitUntilEnded(_ session: TransientPlaybackSession) async {
        // The default controller's analysis finishes on other threads, so fall back to short sleeps.
        for attempt in 0..<400 where session.isEnded == false {
            if attempt < 200 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await session.awaitCleanup()
    }

    private func makeSession(
        titles: [String], analysisCacheDirectory: URL? = nil
    ) throws -> TransientPlaybackSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransientPlaybackSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = titles.map { title in
            MediaItem(
                title: title, duration: 1, isVideo: false, bookmarkData: Data(), fileName: "\(title).wav",
                musicLibraryItemID: title
            )
        }
        return TransientPlaybackSession(
            directory: directory, items: items, analysisCacheDirectory: analysisCacheDirectory
        )
    }

    private func urls(for session: TransientPlaybackSession) -> [UUID: URL] {
        Dictionary(uniqueKeysWithValues: session.items.map {
            ($0.id, session.directory.appendingPathComponent($0.fileName))
        })
    }
}

private actor BlockingAnalysis {
    private var request: CheckedContinuation<MusicAnalysis, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func analyze() async -> MusicAnalysis {
        await withCheckedContinuation { continuation in
            request = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if request != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() {
        request?.resume(returning: MusicAnalysis(duration: 8))
        request = nil
    }
}

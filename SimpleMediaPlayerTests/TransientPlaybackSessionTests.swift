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
        await session.awaitCleanup()

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
        await session.awaitCleanup()

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
        await first.awaitCleanup()

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
        await session.awaitCleanup()

        #expect(session.isEnded)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.player.transientSession == nil)
        #expect(fixture.player.errorMessage != nil)
    }

    private func makeSession(titles: [String]) throws -> TransientPlaybackSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransientPlaybackSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = titles.map { title in
            MediaItem(
                title: title, duration: 1, isVideo: false, bookmarkData: Data(), fileName: "\(title).wav",
                musicLibraryItemID: title
            )
        }
        return TransientPlaybackSession(directory: directory, items: items)
    }

    private func urls(for session: TransientPlaybackSession) -> [UUID: URL] {
        Dictionary(uniqueKeysWithValues: session.items.map {
            ($0.id, session.directory.appendingPathComponent($0.fileName))
        })
    }
}

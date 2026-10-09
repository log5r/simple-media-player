import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct PlaylistOrderingTests {
    @Test func reorderAfterLibraryDeletionUsesVisibleOffsetsAndPersists() async throws {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let playlist = makePlaylist(["A", "Deleted", "B", "C"])
        context.insert(playlist)
        for entry in playlist.entries {
            context.insert(entry)
            if let item = entry.item { context.insert(item) }
        }
        try context.save()
        let deleted = try #require(playlist.orderedItems.first { $0.title == "Deleted" })
        let sharedPlaylist = Playlist(name: "Shared")
        let sharedEntry = PlaylistEntry(sortIndex: 0, playlist: sharedPlaylist, item: deleted)
        sharedPlaylist.entries = [sharedEntry]
        context.insert(sharedPlaylist)
        context.insert(sharedEntry)
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deletedFile = directory.appendingPathComponent(deleted.fileName)
        try Data("audio".utf8).write(to: deletedFile)
        await LibraryService(mediaDirectoryURL: directory).delete(deleted, from: context)?.value

        #expect(FileManager.default.fileExists(atPath: deletedFile.path) == false)
        #expect(try context.fetchCount(FetchDescriptor<MediaItem>()) == 3)
        let reorderContext = ModelContext(container)
        let reloadedPlaylists = try reorderContext.fetch(FetchDescriptor<Playlist>())
        let reloaded = try #require(reloadedPlaylists.first { $0.id == playlist.id })
        let reloadedShared = try #require(reloadedPlaylists.first { $0.id == sharedPlaylist.id })
        try #require(reloaded.orderedEntries.count == 4)
        try #require(reloadedShared.orderedEntries.count == 1)
        try #require(reloaded.orderedEntries[1].item == nil)
        try #require(reloadedShared.orderedEntries.first?.item == nil)
        #expect(reloaded.orderedItems.map(\.title) == ["A", "B", "C"])
        #expect(reloadedShared.orderedItems.isEmpty)

        reloaded.moveItems(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(reloaded.orderedItems.map(\.title) == ["B", "A", "C"])
        try reorderContext.save()
        let verificationContext = ModelContext(container)
        let saved = try #require(verificationContext.fetch(FetchDescriptor<Playlist>()).first { $0.id == playlist.id })
        #expect(saved.orderedItems.map(\.title) == ["B", "A", "C"])
        #expect(saved.orderedEntries.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test(arguments: [
        ([0], 5, ["B", "C", "D", "E", "A"]),
        ([4], 0, ["E", "A", "B", "C", "D"]),
        ([1, 3], 0, ["B", "D", "A", "C", "E"]),
        ([0, 2], 5, ["B", "D", "E", "A", "C"]),
        ([1, 2], 4, ["A", "D", "B", "C", "E"]),
        ([1, 2], 2, ["A", "B", "C", "D", "E"])
    ])
    func dragMovesVisibleItemsAcrossMissingEntries(source: [Int], destination: Int, expected: [String]) {
        let playlist = makePlaylist([nil, "A", nil, "B", "C", nil, "D", "E", nil])
        let missingIDs = playlist.orderedEntries.filter { $0.item == nil }.map(\.id)

        playlist.moveItems(fromOffsets: IndexSet(source), toOffset: destination)

        #expect(playlist.orderedItems.map(\.title) == expected)
        #expect(playlist.orderedEntries.map(\.sortIndex) == Array(0..<9))
        #expect(playlist.orderedEntries.filter { $0.item == nil }.map(\.id) == missingIDs)
    }

    @Test(arguments: [(-1, ["B", "A", "C"]), (1, ["A", "C", "B"])])
    func adjacentMovesSkipMissingEntries(offset: Int, expected: [String]) throws {
        let playlist = makePlaylist([nil, "A", nil, "B", nil, "C", nil])
        let item = try #require(playlist.orderedItems.first { $0.title == "B" })

        playlist.moveItem(item, by: offset)

        #expect(playlist.orderedItems.map(\.title) == expected)
        #expect(playlist.orderedEntries.map(\.sortIndex) == Array(0..<7))
    }

    @Test func adjacentMovesAtBoundariesOrForMissingItemsDoNothing() throws {
        let playlist = makePlaylist([nil, "A", nil, "B", nil, "C", nil])
        let first = try #require(playlist.orderedItems.first)
        let last = try #require(playlist.orderedItems.last)
        let absent = try #require(makePlaylist(["Absent"]).orderedItems.first)
        let originalIDs = playlist.orderedEntries.map(\.id)

        playlist.moveItem(first, by: -1)
        playlist.moveItem(last, by: 1)
        playlist.moveItem(first, by: 0)
        playlist.moveItem(absent, by: 1)

        #expect(playlist.orderedEntries.map(\.id) == originalIDs)
        #expect(playlist.orderedEntries.map(\.sortIndex) == Array(0..<7))
    }

    @Test(arguments: [([], 0), ([3], 0), ([0], -1), ([0], 4)])
    func invalidOrEmptyDragDoesNotChangeOrder(source: [Int], destination: Int) {
        let playlist = makePlaylist(["A", nil, "B", "C"])
        let originalIDs = playlist.orderedEntries.map(\.id)

        playlist.moveItems(fromOffsets: IndexSet(source), toOffset: destination)

        #expect(playlist.orderedEntries.map(\.id) == originalIDs)
        #expect(playlist.orderedItems.map(\.title) == ["A", "B", "C"])
    }

    @Test func emptyAndEntirelyMissingPlaylistsDoNotReorder() {
        for playlist in [makePlaylist([]), makePlaylist([nil, nil])] {
            let originalIDs = playlist.orderedEntries.map(\.id)

            playlist.moveItems(fromOffsets: IndexSet(integer: 0), toOffset: 0)

            #expect(playlist.orderedEntries.map(\.id) == originalIDs)
            #expect(playlist.orderedItems.isEmpty)
        }
    }

    private func makePlaylist(_ titles: [String?]) -> Playlist {
        let playlist = Playlist(name: "Ordering")
        playlist.entries = titles.enumerated().map { index, title in
            let item = title.map {
                MediaItem(title: $0, duration: 1, isVideo: false, bookmarkData: Data([0xFF]), fileName: "\(index).wav")
            }
            return PlaylistEntry(sortIndex: index, playlist: playlist, item: item)
        }
        return playlist
    }
}

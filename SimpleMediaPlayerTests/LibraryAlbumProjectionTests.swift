import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryAlbumProjectionTests {
    @Test func repeatedReadsAndIdenticalSourcesReuseTheAggregation() throws {
        let items = (1...3_000).map { makeItem("Track \($0)", album: "Album \(($0 - 1) / 30)") }
        let probe = AlbumGroupingProbe()
        let projection = LibraryAlbumProjection(group: probe.group)
        defer { projection.clear() }
        projection.update(items: items)

        for _ in 0..<30 {
            projection.update(items: Array(items))
            let album = try #require(projection.albums.first { $0.id == "Album 0" })
            for item in album.tracks { _ = item.displayArtist == album.artist }
        }

        #expect(projection.albums.count == 100)
        #expect(probe.count == 1)
    }

    @Test func metadataEditsRegroupAndReorderWithoutReplacingTheSourceArray() async throws {
        let first = makeItem("First")
        let second = makeItem("Second")
        first.trackNumber = "1"
        second.trackNumber = "2"
        let projection = LibraryAlbumProjection()
        defer { projection.clear() }
        projection.update(items: [first, second])

        second.discNumber = "1"
        second.albumArtist = " Ensemble "
        second.year = " 2026 "
        second.genre = " Jazz "
        second.artworkID = UUID()
        try await waitUntil { projection.albums.first?.tracks.first === second }
        let album = try #require(projection.albums.first)
        #expect(album.artist == "Ensemble")
        #expect(album.metadataSummary == "2026 • Jazz")
        #expect(album.artworkID == second.artworkID)

        second.album = "Another Album"
        try await waitUntil { projection.albums.count == 2 }
        #expect(projection.albums.map(\.title) == ["Album", "Another Album"])
        #expect(projection.albums.first?.tracks.map(\.id) == [first.id])
    }

    @Test(arguments: AlbumObservedField.allCases)
    private func eachAggregatedFieldInvalidatesTheCache(_ field: AlbumObservedField) async throws {
        let first = makeItem("A")
        let second = makeItem("B")
        let probe = AlbumGroupingProbe()
        let projection = LibraryAlbumProjection(group: probe.group)
        defer { projection.clear() }
        projection.update(items: [first, second])

        field.change(first)
        try await waitUntil { probe.count == 2 }
    }

    @Test func artistAndTitleEditsUpdateTheSummaryAndTrackOrder() async throws {
        let first = makeItem("A")
        let second = makeItem("B")
        let projection = LibraryAlbumProjection()
        defer { projection.clear() }
        projection.update(items: [first, second])

        first.artist = "Guest"
        try await waitUntil { projection.albums.first?.artist == L10n.string("Various Artists") }
        first.title = "Z"
        try await waitUntil { projection.albums.first?.tracks.first === second }
        second.trackNumber = "2"
        first.trackNumber = "1"
        try await waitUntil { projection.albums.first?.tracks.first === first }
        first.artist = second.artist
        try await waitUntil { projection.albums.first?.artist == "Artist" }
    }

    @Test func removingArtworkAndSummaryValuesDoesNotRetainCachedValues() async throws {
        let item = makeItem("Song")
        item.artworkID = UUID()
        item.albumArtist = "Ensemble"
        item.year = "2026"
        item.genre = "Jazz"
        let projection = LibraryAlbumProjection()
        defer { projection.clear() }
        projection.update(items: [item])

        item.artworkID = nil
        item.albumArtist = nil
        item.year = nil
        item.genre = nil
        try await waitUntil { projection.albums.first?.artworkID == nil }
        #expect(projection.albums.first?.artist == "Artist")
        #expect(projection.albums.first?.metadataSummary == "")
    }

    @Test func importDeletionAndFilteringReplaceTheRetainedTracks() {
        let first = makeItem("First")
        let imported = makeItem("Imported", album: "Imported Album")
        let projection = LibraryAlbumProjection()
        defer { projection.clear() }
        projection.update(items: [first])
        projection.update(items: [first, imported])
        #expect(projection.albums.map(\.title) == ["Album", "Imported Album"])
        projection.update(items: [imported])
        #expect(projection.albums.first?.tracks.map(\.id) == [imported.id])
        projection.update(items: [])
        #expect(projection.albums.isEmpty)
        projection.update(items: [first, imported])
        #expect(projection.albums.count == 2)
    }

    @Test func queuedEditsCannotRefreshAReplacedSourceOrAClearedProjection() async throws {
        let old = makeItem("Old")
        let replacement = makeItem("Replacement", album: "Replacement Album")
        replacement.id = old.id
        let probe = AlbumGroupingProbe()
        let projection = LibraryAlbumProjection(group: probe.group)
        defer { projection.clear() }
        projection.update(items: [old])
        old.album = "Queued Edit"
        projection.update(items: [replacement])
        old.album = "Retired Source"
        try await Task.sleep(for: .milliseconds(20))
        #expect(probe.count == 2)
        #expect(projection.albums.first?.tracks.first === replacement)

        replacement.album = "Queued Before Clear"
        projection.clear()
        try await Task.sleep(for: .milliseconds(20))
        #expect(projection.albums.isEmpty)
        #expect(probe.count == 2)
        projection.update(items: [replacement])
        replacement.album = "Reappeared"
        try await waitUntil { projection.albums.first?.title == "Reappeared" }
        #expect(probe.count == 4)
    }

    private func makeItem(_ title: String, album: String = "Album") -> MediaItem {
        MediaItem(
            title: title, artist: "Artist", album: album, duration: 120,
            isVideo: false, bookmarkData: Data(), fileName: "song.mp3"
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while condition() == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition(), "The album projection did not update")
    }
}

private enum AlbumObservedField: CaseIterable {
    case title, artist, album, albumArtist, trackNumber, discNumber, year, genre, artworkID

    @MainActor func change(_ item: MediaItem) {
        switch self {
        case .title: item.title = "Z"
        case .artist: item.artist = "Guest"
        case .album: item.album = "Another Album"
        case .albumArtist: item.albumArtist = "Ensemble"
        case .trackNumber: item.trackNumber = "2"
        case .discNumber: item.discNumber = "2"
        case .year: item.year = "2026"
        case .genre: item.genre = "Jazz"
        case .artworkID: item.artworkID = UUID()
        }
    }
}

@MainActor
final class AlbumGroupingProbe {
    private(set) var count = 0

    func group(_ items: [MediaItem]) -> [LibraryAlbum] {
        count += 1
        return LibraryAlbum.grouped(items)
    }
}

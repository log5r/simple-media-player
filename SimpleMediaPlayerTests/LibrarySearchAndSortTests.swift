import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibrarySearchAndSortTests {
    @Test func preparedSearchTrimsQueriesAndPreservesCaseAndDiacriticMatching() {
        let item = makeItem(title: "Clair de Lune", artist: "Claude Debussy", album: "Études")
        item.composer = "Gabriel Fauré"
        let filter = LibrarySearchFilter(album: " \nETUDES\t", composer: "faure ")
        let prepared = filter.prepared(searchText: "  clair\n")

        #expect(prepared.matches(item))
        #expect(filter.activeCriteriaCount == 2)
        #expect(filter.prepared(searchText: "missing").matches(item) == false)
    }

    @Test func preparedOrSearchStillRequiresTheGeneralQuery() {
        let artistMatch = makeItem(title: "Blue in Green", artist: "Miles Davis")
        let genreMatch = makeItem(title: "Green Fields", artist: "Someone Else")
        genreMatch.genre = "Ambient"
        let wrongGeneralQuery = makeItem(title: "So What", artist: "Miles Davis")
        let prepared = LibrarySearchFilter(artist: "miles", genre: "ambient", matchMode: .any)
            .prepared(searchText: "green")

        #expect(prepared.matches(artistMatch))
        #expect(prepared.matches(genreMatch))
        #expect(prepared.matches(wrongGeneralQuery) == false)
    }

    @Test func preparedSearchIgnoresWhitespaceAndHandlesAbsentOptionalMetadata() {
        let item = makeItem(title: "Song")
        let empty = LibrarySearchFilter(title: " \n", composer: "\t", matchMode: .any)

        #expect(empty.activeCriteriaCount == 0)
        #expect(empty.prepared(searchText: "\n ").matches(item))
        #expect(LibrarySearchFilter(albumArtist: "ensemble").prepared().matches(item) == false)
        #expect(LibrarySearchFilter(composer: "debussy").prepared().matches(item) == false)
        #expect(LibrarySearchFilter(genre: "jazz").prepared().matches(item) == false)
    }

    @Test func preparedSearchSnapshotsCriteriaAndReadsCurrentItemMetadata() {
        let item = makeItem(title: "Song", artist: "Miles Davis")
        var filter = LibrarySearchFilter(artist: "miles")
        let prepared = filter.prepared()
        filter.artist = "debussy"

        #expect(prepared.matches(item))
        #expect(filter.prepared().matches(item) == false)

        item.artist = "Claude Debussy"

        #expect(prepared.matches(item) == false)
        #expect(filter.prepared().matches(item))
    }

    @Test func sortFallbackUsesEachFieldAndStaysAscendingForDescendingPrimarySort() {
        let title = makeItem(title: "Alpha", artist: "Z", album: "Z", fileName: "z.mp3")
        let artist = makeItem(title: "Same", artist: "Alpha", album: "Z", fileName: "z.mp3")
        let album = makeItem(title: "Same", artist: "Same", album: "Alpha", fileName: "z.mp3")
        let fileName = makeItem(title: "Same", artist: "Same", album: "Same", fileName: "alpha.mp3")
        let identifier = makeItem(
            title: "Same", artist: "Same", album: "Same", fileName: "same.mp3", identifier: 1
        )
        let last = makeItem(title: "Same", artist: "Same", album: "Same", fileName: "same.mp3", identifier: 2)
        let expected = [title, artist, album, fileName, identifier, last].map(\.id)
        let input = [last, album, title, fileName, artist, identifier]

        #expect(LibrarySortField.duration.sorted(input, direction: .ascending).map(\.id) == expected)
        #expect(LibrarySortField.duration.sorted(input, direction: .descending).map(\.id) == expected)
    }

    @Test func cancellableSortPreservesOrderingWhenNotCancelled() throws {
        let items = [makeItem(title: "Gamma"), makeItem(title: "Alpha"), makeItem(title: "Beta")]
        let result = try LibrarySortField.title.sorted(items, direction: .descending, cancellationCheck: { false })

        #expect(result.map(\.id) == LibrarySortField.title.sorted(items, direction: .descending).map(\.id))
    }

    @Test func cancellableSortStopsBeforeStartingAndDuringComparison() {
        let items = (1...1024).reversed().map { makeItem(title: "Track \($0)") }
        #expect(throws: CancellationError.self) {
            try LibrarySortField.title.sorted(items, direction: .ascending, cancellationCheck: { true })
        }

        var checks = 0
        #expect(throws: CancellationError.self) {
            try LibrarySortField.title.sorted(items, direction: .ascending) {
                checks += 1
                return checks > 1
            }
        }
        #expect(checks == 2)
    }

    @Test func cancellableSortRejectsAResultCancelledAfterTheLastComparison() {
        let items = [makeItem(title: "Beta"), makeItem(title: "Alpha")]
        var checks = 0
        #expect(throws: CancellationError.self) {
            try LibrarySortField.title.sorted(items, direction: .ascending) {
                checks += 1
                return checks > 1
            }
        }
        #expect(checks == 2)
    }

    private func makeItem(
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        fileName: String = "song.mp3",
        identifier: Int? = nil
    ) -> MediaItem {
        let id = identifier.map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
            ?? UUID()
        return MediaItem(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: 120,
            isVideo: false,
            bookmarkData: Data(),
            fileName: fileName
        )
    }
}

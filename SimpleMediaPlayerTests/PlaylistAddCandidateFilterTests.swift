import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct PlaylistAddCandidateFilterTests {
    @Test func emptyQueryKeepsEveryItemNotInThePlaylistInOrder() {
        let items = (1...5).map { makeItem(title: "Song \($0)", identifier: $0) }
        let excluded: Set<UUID> = [items[1].id, items[3].id]

        let candidates = PlaylistAddCandidateFilter.candidates(from: items, excluding: excluded, searchText: "")

        #expect(candidates.map(\.id) == [items[0].id, items[2].id, items[4].id])
    }

    @Test func queryIgnoresCaseAndMatchesTitleArtistAlbumAndGenre() {
        let title = makeItem(title: "Blue in Green", identifier: 1)
        let artist = makeItem(title: "Song", artist: "GREEN Day", identifier: 2)
        let album = makeItem(title: "Song", album: "Evergreen", identifier: 3)
        let genre = makeItem(title: "Song", genre: "Green Jazz", identifier: 4)
        let other = makeItem(title: "So What", genre: "Jazz", identifier: 5)
        let items = [other, genre, album, artist, title]

        let candidates = PlaylistAddCandidateFilter.candidates(from: items, excluding: [], searchText: "gReEn")

        #expect(candidates.map(\.id) == [genre.id, album.id, artist.id, title.id])
    }

    @Test func absentGenreMatchesOnlyThroughOtherFields() {
        let item = makeItem(title: "Song", genre: nil, identifier: 1)

        #expect(PlaylistAddCandidateFilter.candidates(from: [item], excluding: [], searchText: "jazz").isEmpty)
        #expect(PlaylistAddCandidateFilter.candidates(from: [item], excluding: [], searchText: "SONG").count == 1)
    }

    @Test func matchingStaysSensitiveToDiacritics() {
        let accented = makeItem(title: "Café", identifier: 1)
        let plain = makeItem(title: "Cafe", identifier: 2)
        let items = [accented, plain]

        let plainQuery = PlaylistAddCandidateFilter.candidates(from: items, excluding: [], searchText: "cafe")
        let accentedQuery = PlaylistAddCandidateFilter.candidates(from: items, excluding: [], searchText: "CAFÉ")

        #expect(plainQuery.map(\.id) == [plain.id])
        #expect(accentedQuery.map(\.id) == [accented.id])
    }

    @Test func excludedItemsStayHiddenEvenWhenTheyMatch() {
        let inPlaylist = makeItem(title: "Green", identifier: 1)
        let notInPlaylist = makeItem(title: "Green", identifier: 2)

        let candidates = PlaylistAddCandidateFilter.candidates(
            from: [inPlaylist, notInPlaylist], excluding: [inPlaylist.id], searchText: "green"
        )

        #expect(candidates.map(\.id) == [notInPlaylist.id])
    }

    @Test func resultsMatchThePreviousPerItemLowercasing() {
        let titles = [
            "Café", "Cafe\u{301}", "CAFE", "Straße", "STRASSE", "İstanbul", "ISTANBUL", "ΟΔΟΣ", "οδος", " ", "",
            "ﬁne", "FINE", "Ǆemal"
        ]
        let items = titles.enumerated().map { makeItem(title: $1, identifier: $0 + 1) }
        let excluded: Set<UUID> = [items[2].id]
        let queries = ["", " ", "café", "cafe\u{301}", "CAFE", "ss", "ß", "i̇", "istanbul", "σ", "ς", "fi", "ǆ", "x"]

        for query in queries {
            let expected = previousCandidates(items: items, existingIDs: excluded, searchText: query)
            let actual = PlaylistAddCandidateFilter.candidates(from: items, excluding: excluded, searchText: query)
            #expect(actual.map(\.id) == expected.map(\.id), "query: \(query)")
        }
    }

    /// The filter that `PlaylistAddItemsView.candidates` used before it was extracted.
    private func previousCandidates(items: [MediaItem], existingIDs: Set<UUID>, searchText: String) -> [MediaItem] {
        items
            .filter { existingIDs.contains($0.id) == false }
            .filter { item in
                guard searchText.isEmpty == false else { return true }
                let query = searchText.localizedLowercase
                return [item.title, item.artist, item.album, item.genre ?? ""].contains {
                    $0.localizedLowercase.contains(query)
                }
            }
    }

    private func makeItem(
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        genre: String? = nil,
        identifier: Int
    ) -> MediaItem {
        MediaItem(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", identifier))!,
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            duration: 120,
            isVideo: false,
            bookmarkData: Data(),
            fileName: "song.mp3"
        )
    }
}

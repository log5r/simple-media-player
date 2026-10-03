import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryAlbumTests {
    @Test func singleArtistUsesTheTrimmedDisplayName() throws {
        let item = makeItem(title: "Song", artist: " \nBjörk\t")

        let album = try #require(LibraryAlbum.grouped([item]).first)

        #expect(album.artist == "Björk")
        #expect(album.tracks.map(\.id) == [item.id])
    }

    @Test func equivalentDisplayArtistsKeepTheFirstSortedTrackName() throws {
        let later = makeItem(title: "Later", artist: "\tEnsemble\n", trackNumber: "2")
        let first = makeItem(title: "First", artist: " Ensemble ", trackNumber: "1")
        try #require(first.displayArtist.localizedStandardCompare(later.displayArtist) == .orderedSame)

        let album = try #require(LibraryAlbum.grouped([later, first]).first)

        #expect(album.tracks.map(\.id) == [first.id, later.id])
        #expect(album.artist == first.displayArtist)
        #expect(album.artist == "Ensemble")
    }

    @Test(arguments: [
        ("Artist", "Another Artist"),
        ("Artist", "ARTIST"),
        ("Björk", "BJORK"),
        ("é", "e\u{301}"),
        ("Artist", "Ａｒｔｉｓｔ"),
        ("Artist 2", "Artist 02"),
        ("Artist", "Artists")
    ])
    func distinctLocalizedArtistComparisonsUseVariousArtists(first: String, second: String) throws {
        // localizedStandardCompare retains its forced ordering for spelling variants,
        // including canonical Unicode equivalents that Swift String considers equal.
        try #require(first.localizedStandardCompare(second) != .orderedSame)
        let tracks = [
            makeItem(title: "First", artist: first, trackNumber: "1"),
            makeItem(title: "Second", artist: second, trackNumber: "2")
        ]

        let album = try #require(LibraryAlbum.grouped(tracks).first)

        #expect(album.artist == L10n.string("Various Artists"))
    }

    @Test func unknownMetadataDefaultsAndBlankValuesShareLocalizedNames() throws {
        let defaultMetadata = MediaItem(
            title: "First", duration: 120, isVideo: false, bookmarkData: Data(), fileName: "first.mp3"
        )
        let blankMetadata = makeItem(title: "Second", artist: " \n", album: "\t")

        let albums = LibraryAlbum.grouped([blankMetadata, defaultMetadata])
        let album = try #require(albums.first)

        #expect(albums.count == 1)
        #expect(album.title == L10n.string("Unknown Album"))
        #expect(album.artist == L10n.string("Unknown Artist"))
        #expect(album.tracks.count == 2)
    }

    @Test func firstNonBlankAlbumArtistOverridesDistinctTrackArtists() throws {
        let blank = makeItem(title: "First", artist: "Soloist", albumArtist: " \n", trackNumber: "1")
        let chosen = makeItem(title: "Second", artist: "Guest", albumArtist: " Ensemble \t", trackNumber: "2")
        let later = makeItem(title: "Third", artist: "Another Guest", albumArtist: "Other Ensemble", trackNumber: "3")

        let album = try #require(LibraryAlbum.grouped([later, chosen, blank]).first)

        #expect(album.artist == "Ensemble")
        #expect(album.tracks.map(\.id) == [blank.id, chosen.id, later.id])
    }

    @Test(arguments: [false, true])
    func blankAlbumArtistsFallBackToTrackArtistSummary(hasDistinctArtists: Bool) throws {
        let first = makeItem(title: "First", artist: "Ensemble", albumArtist: " \n", trackNumber: "1")
        let second = makeItem(
            title: "Second", artist: hasDistinctArtists ? "Guest" : "Ensemble",
            albumArtist: "\t", trackNumber: "2"
        )

        let album = try #require(LibraryAlbum.grouped([second, first]).first)

        #expect(album.artist == (hasDistinctArtists ? L10n.string("Various Artists") : "Ensemble"))
    }

    @Test(arguments: [false, true])
    func largeUnknownAlbumSummarizesAllTracks(hasDistinctArtists: Bool) throws {
        let tracks = (1...3_000).map { index in
            makeItem(
                title: "Track \(index)", artist: hasDistinctArtists ? "Artist \(index)" : "Ensemble",
                album: "Unknown Album", trackNumber: "\(index)"
            )
        }

        let albums = LibraryAlbum.grouped(tracks.reversed())
        let album = try #require(albums.first)

        #expect(albums.count == 1)
        #expect(album.title == L10n.string("Unknown Album"))
        #expect(album.artist == (hasDistinctArtists ? L10n.string("Various Artists") : "Ensemble"))
        #expect(album.tracks.map(\.id) == tracks.map(\.id))
    }

    private func makeItem(
        title: String,
        artist: String,
        album: String = "Album",
        albumArtist: String? = nil,
        trackNumber: String? = nil
    ) -> MediaItem {
        MediaItem(
            title: title,
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            albumArtist: albumArtist,
            duration: 120,
            isVideo: false,
            bookmarkData: Data(),
            fileName: "song.mp3"
        )
    }
}

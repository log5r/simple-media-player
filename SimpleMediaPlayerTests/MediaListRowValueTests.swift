import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MediaListRowValueTests {
    @Test(arguments: [
        ("song.mp3", "MP3"), ("song.AAC", "AAC"), ("a.b.flac", "FLAC"), ("曲.Opus", "OPUS"),
        ("song", "-"), (".mp3", "-"), ("song.", "-"), ("song.m p3", "-"), ("song.mp3 ", "-")
    ])
    func contentTypeMatchesFileURLPathExtensionWithoutFileSystemQuery(fileName: String, expected: String) {
        let item = MediaItem(title: "Song", duration: 1, isVideo: false, bookmarkData: Data(), fileName: fileName)
        #expect(item.displayContentType == expected)
        let formerExtension = URL(fileURLWithPath: fileName).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(item.displayContentType == (formerExtension.isEmpty ? "-" : formerExtension.uppercased()))
    }

    @Test func tableSortKeyPathsMapToLibrarySortFields() {
        let expected: [(PartialKeyPath<MediaTableRow>, LibrarySortField)] = [
            (\.indexSortValue, .dateAdded), (\.artworkSortValue, .title), (\.titleSortValue, .title),
            (\.artistSortValue, .artist), (\.albumSortValue, .album), (\.genreSortValue, .genre),
            (\.durationSortValue, .duration), (\.trackNumberSortValue, .trackNumber), (\.yearSortValue, .year),
            (\.albumArtistSortValue, .albumArtist), (\.composerSortValue, .composer),
            (\.discNumberSortValue, .discNumber), (\.kindSortValue, .kind),
            (\.contentTypeSortValue, .contentType), (\.dateAddedSortValue, .dateAdded),
            (\.fileNameSortValue, .fileName)
        ]
        for (keyPath, field) in expected {
            #expect(MediaTableRow.sortField(forKeyPathDescription: String(describing: keyPath)) == field)
        }
    }
}

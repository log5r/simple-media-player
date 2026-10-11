import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MediaListRowValueTests {
    @Test(arguments: [
        ("song.mp3", "MP3"), ("song.AAC", "AAC"), ("a.b.flac", "FLAC"), ("曲.Opus", "OPUS"),
        ("song", "-"), (".mp3", "-"), ("song.", "-"), ("song.m p3", "-"), ("song.mp3 ", "-")
    ])
    func contentTypeMatchesFileURLPathExtensionWithoutFileSystemQuery(
        fileName: String, expected: String
    ) {
        let item = MediaItem(title: "Song", duration: 1, isVideo: false, bookmarkData: Data(), fileName: fileName)
        #expect(item.displayContentType == expected)
        let formerExtension = URL(fileURLWithPath: fileName).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(item.displayContentType == (formerExtension.isEmpty ? "-" : formerExtension.uppercased()))
    }

    @Test func tableSortKeyPathsMapToLibrarySortFields() {
        let expected: [(KeyPathComparator<MediaTableRow>, LibrarySortField)] = [
            (.init(\.indexSortValue), .dateAdded), (.init(\.artworkSortValue), .title),
            (.init(\.titleSortValue), .title), (.init(\.artistSortValue), .artist),
            (.init(\.albumSortValue), .album), (.init(\.genreSortValue), .genre),
            (.init(\.durationSortValue), .duration), (.init(\.trackNumberSortValue), .trackNumber),
            (.init(\.yearSortValue), .year), (.init(\.albumArtistSortValue), .albumArtist),
            (.init(\.composerSortValue), .composer), (.init(\.discNumberSortValue), .discNumber),
            (.init(\.kindSortValue), .kind), (.init(\.contentTypeSortValue), .contentType),
            (.init(\.dateAddedSortValue), .dateAdded), (.init(\.fileNameSortValue), .fileName)
        ]
        for (comparator, field) in expected {
            #expect(MediaTableRow.sortField(for: comparator.keyPath) == field)
        }
        #expect(MediaTableRow.sortField(for: \.id) == nil)
    }
}

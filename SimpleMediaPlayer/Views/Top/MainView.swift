import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

enum LibrarySection: String, CaseIterable, Identifiable {
    case allSongs
    case allVideos
    case albums
    case artists
    case genres

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allSongs: L10n.string("All Songs")
        case .allVideos: L10n.string("All Videos")
        case .albums: L10n.string("Albums")
        case .artists: L10n.string("Artists")
        case .genres: L10n.string("Genres")
        }
    }

    var icon: String {
        switch self {
        case .allSongs: "music.note"
        case .allVideos: "film"
        case .albums: "opticaldisc"
        case .artists: "person"
        case .genres: "tag"
        }
    }
}

enum SidebarSelection: Hashable {
    case library(LibrarySection)
    case playlist(UUID)
}

enum LibrarySortField: String, CaseIterable, Identifiable {
    case dateAdded
    case title
    case artist
    case album
    case genre
    case duration
    case trackNumber
    case year
    case albumArtist
    case composer
    case discNumber
    case kind
    case contentType
    case fileName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateAdded: L10n.string("Date Added")
        case .title: L10n.string("Title")
        case .artist: L10n.string("Artist")
        case .album: L10n.string("Album")
        case .genre: L10n.string("Genre")
        case .duration: L10n.string("Time")
        case .trackNumber: L10n.string("Track")
        case .year: L10n.string("Year")
        case .albumArtist: L10n.string("Album Artist")
        case .composer: L10n.string("Composer")
        case .discNumber: L10n.string("Disc")
        case .kind: L10n.string("Kind")
        case .contentType: L10n.string("Content Type")
        case .fileName: L10n.string("File Name")
        }
    }

    var icon: String {
        switch self {
        case .dateAdded: "calendar.badge.plus"
        case .title: "textformat"
        case .artist: "person"
        case .album: "opticaldisc"
        case .genre: "tag"
        case .duration: "clock"
        case .trackNumber: "list.number"
        case .year: "calendar"
        case .albumArtist: "person.2"
        case .composer: "pencil.and.list.clipboard"
        case .discNumber: "opticaldisc"
        case .kind: "waveform"
        case .contentType: "doc.richtext"
        case .fileName: "doc"
        }
    }

    init?(column: MediaListColumn) {
        switch column {
        case .title:
            self = .title
        case .artist:
            self = .artist
        case .album:
            self = .album
        case .genre:
            self = .genre
        case .duration:
            self = .duration
        case .trackNumber:
            self = .trackNumber
        case .year:
            self = .year
        case .albumArtist:
            self = .albumArtist
        case .composer:
            self = .composer
        case .discNumber:
            self = .discNumber
        case .kind:
            self = .kind
        case .contentType:
            self = .contentType
        case .dateAdded:
            self = .dateAdded
        case .fileName:
            self = .fileName
        case .index, .artwork:
            return nil
        }
    }

    func sorted(_ items: [MediaItem], direction: LibrarySortDirection) -> [MediaItem] {
        items.sorted { lhs, rhs in
            let comparison = compare(lhs, rhs)
            if comparison != .orderedSame {
                return direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }

            return fallbackCompare(lhs, rhs) == .orderedAscending
        }
    }

    private func compare(_ lhs: MediaItem, _ rhs: MediaItem) -> ComparisonResult {
        switch self {
        case .dateAdded:
            compare(lhs.addedAt, rhs.addedAt)
        case .title:
            compare(lhs.title, rhs.title)
        case .artist:
            compare(lhs.displayArtist, rhs.displayArtist)
        case .album:
            compare(lhs.displayAlbum, rhs.displayAlbum)
        case .genre:
            compare(lhs.displayGenre, rhs.displayGenre)
        case .duration:
            compare(lhs.duration, rhs.duration)
        case .trackNumber:
            compareNumberMetadata(lhs.trackNumber, rhs.trackNumber)
        case .year:
            compareNumberMetadata(lhs.year, rhs.year)
        case .albumArtist:
            compareMetadata(lhs.albumArtist, rhs.albumArtist)
        case .composer:
            compareMetadata(lhs.composer, rhs.composer)
        case .discNumber:
            compareNumberMetadata(lhs.discNumber, rhs.discNumber)
        case .kind:
            compare(
                lhs.isVideo ? L10n.string("Video") : L10n.string("Audio"),
                rhs.isVideo ? L10n.string("Video") : L10n.string("Audio")
            )
        case .contentType:
            compare(lhs.displayContentType, rhs.displayContentType)
        case .fileName:
            compare(lhs.fileName, rhs.fileName)
        }
    }

    private func fallbackCompare(_ lhs: MediaItem, _ rhs: MediaItem) -> ComparisonResult {
        for comparison in [
            compare(lhs.title, rhs.title),
            compare(lhs.displayArtist, rhs.displayArtist),
            compare(lhs.displayAlbum, rhs.displayAlbum),
            compare(lhs.fileName, rhs.fileName),
            compare(lhs.id.uuidString, rhs.id.uuidString)
        ] where comparison != .orderedSame {
            return comparison
        }

        return .orderedSame
    }

    private func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }

    private func compare(_ lhs: TimeInterval, _ rhs: TimeInterval) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func compare(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func compareMetadata(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        compare(normalizedMetadata(lhs), normalizedMetadata(rhs))
    }

    private func compareNumberMetadata(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        let lhsNumber = leadingNumber(in: lhs)
        let rhsNumber = leadingNumber(in: rhs)

        switch (lhsNumber, rhsNumber) {
        case let (lhsNumber?, rhsNumber?) where lhsNumber != rhsNumber:
            return compare(TimeInterval(lhsNumber), TimeInterval(rhsNumber))
        case (_?, nil):
            return .orderedAscending
        case (nil, _?):
            return .orderedDescending
        default:
            return compareMetadata(lhs, rhs)
        }
    }

    private func normalizedMetadata(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func leadingNumber(in value: String?) -> Int? {
        let trimmed = normalizedMetadata(value)
        let prefix = trimmed.prefix { $0.isNumber }
        guard prefix.isEmpty == false else { return nil }
        return Int(prefix)
    }
}

enum LibrarySortDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: L10n.string("Ascending")
        case .descending: L10n.string("Descending")
        }
    }

    var icon: String {
        switch self {
        case .ascending: "arrow.up"
        case .descending: "arrow.down"
        }
    }

    var sortOrder: SortOrder {
        switch self {
        case .ascending: .forward
        case .descending: .reverse
        }
    }

    init(sortOrder: SortOrder) {
        switch sortOrder {
        case .forward:
            self = .ascending
        case .reverse:
            self = .descending
        }
    }
}

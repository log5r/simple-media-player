import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

nonisolated enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
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

nonisolated enum LibrarySortField: String, CaseIterable, Identifiable, Sendable {
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

    func sorted<Item: LibraryListItemValues>(_ items: [Item], direction: LibrarySortDirection) -> [Item] {
        items.sorted { lhs, rhs in
            isOrderedBefore(lhs, rhs, direction: direction)
        }
    }

    func sorted<Item: LibraryListItemValues>(
        _ items: [Item],
        direction: LibrarySortDirection,
        cancellationCheck: () -> Bool
    ) throws -> [Item] {
        if cancellationCheck() { throw CancellationError() }
        var comparisonsUntilCancellationCheck = 128
        let sorted = try items.sorted { lhs, rhs in
            comparisonsUntilCancellationCheck -= 1
            if comparisonsUntilCancellationCheck == 0 {
                if cancellationCheck() { throw CancellationError() }
                comparisonsUntilCancellationCheck = 128
            }
            return isOrderedBefore(lhs, rhs, direction: direction)
        }
        if cancellationCheck() { throw CancellationError() }
        return sorted
    }

    private func isOrderedBefore<Item: LibraryListItemValues>(
        _ lhs: Item, _ rhs: Item, direction: LibrarySortDirection
    ) -> Bool {
        let comparison = compare(lhs, rhs)
        if comparison != .orderedSame {
            return direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return fallbackCompare(lhs, rhs) == .orderedAscending
    }

    private func compare<Item: LibraryListItemValues>(_ lhs: Item, _ rhs: Item) -> ComparisonResult {
        switch self {
        case .dateAdded:
            compare(lhs.addedAt, rhs.addedAt)
        case .duration:
            compare(lhs.duration, rhs.duration)
        case .title, .artist, .album, .genre, .albumArtist, .composer, .contentType, .fileName:
            compare(stringValue(in: lhs), stringValue(in: rhs))
        case .trackNumber, .year, .discNumber:
            compareNumberMetadata(numberMetadata(in: lhs), numberMetadata(in: rhs))
        case .kind:
            compare(
                lhs.isVideo ? L10n.string("Video") : L10n.string("Audio"),
                rhs.isVideo ? L10n.string("Video") : L10n.string("Audio")
            )
        }
    }

    private func stringValue<Item: LibraryListItemValues>(in item: Item) -> String {
        switch self {
        case .title: item.title
        case .artist: item.displayArtist
        case .album: item.displayAlbum
        case .genre: item.displayGenre
        case .albumArtist: normalizedMetadata(item.albumArtist)
        case .composer: normalizedMetadata(item.composer)
        case .contentType: item.displayContentType
        case .fileName: item.fileName
        default: ""
        }
    }

    private func numberMetadata<Item: LibraryListItemValues>(in item: Item) -> String? {
        switch self {
        case .trackNumber: item.trackNumber
        case .year: item.year
        case .discNumber: item.discNumber
        default: nil
        }
    }

    private func fallbackCompare<Item: LibraryListItemValues>(_ lhs: Item, _ rhs: Item) -> ComparisonResult {
        let titleComparison = compare(lhs.title, rhs.title)
        if titleComparison != .orderedSame { return titleComparison }
        let artistComparison = compare(lhs.displayArtist, rhs.displayArtist)
        if artistComparison != .orderedSame { return artistComparison }
        let albumComparison = compare(lhs.displayAlbum, rhs.displayAlbum)
        if albumComparison != .orderedSame { return albumComparison }
        let fileNameComparison = compare(lhs.fileName, rhs.fileName)
        if fileNameComparison != .orderedSame { return fileNameComparison }
        return compare(lhs.id.uuidString, rhs.id.uuidString)
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

nonisolated enum LibrarySortDirection: String, CaseIterable, Identifiable, Sendable {
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

import Foundation

nonisolated enum LibraryFilterMatchMode: String, CaseIterable, Identifiable, Sendable {
    case all
    case any

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.string("All (AND)")
        case .any: L10n.string("Any (OR)")
        }
    }
}

nonisolated struct LibrarySearchFilter: Equatable, Sendable {
    var title = ""
    var album = ""
    var artist = ""
    var albumArtist = ""
    var composer = ""
    var genre = ""
    var matchMode: LibraryFilterMatchMode = .all

    var isActive: Bool {
        activeCriteria.isEmpty == false
    }

    var activeCriteriaCount: Int {
        activeCriteria.count
    }

    mutating func clear() {
        title = ""
        album = ""
        artist = ""
        albumArtist = ""
        composer = ""
        genre = ""
    }

    func matches<Item: LibraryListItemValues>(_ item: Item, searchText: String = "") -> Bool {
        prepared(searchText: searchText).matches(item)
    }

    func prepared(searchText: String = "") -> Prepared {
        Prepared(searchQuery: normalized(searchText), criteria: activeCriteria, matchMode: matchMode)
    }

    nonisolated struct Prepared: Sendable {
        fileprivate let searchQuery: String
        fileprivate let criteria: [Criterion]
        fileprivate let matchMode: LibraryFilterMatchMode

        func matches<Item: LibraryListItemValues>(_ item: Item) -> Bool {
            if searchQuery.isEmpty == false {
                guard LibrarySearchFilter.contains(searchQuery, in: item.title)
                    || LibrarySearchFilter.contains(searchQuery, in: item.artist)
                    || LibrarySearchFilter.contains(searchQuery, in: item.album)
                    || LibrarySearchFilter.contains(searchQuery, in: item.albumArtist ?? "")
                    || LibrarySearchFilter.contains(searchQuery, in: item.composer ?? "")
                    || LibrarySearchFilter.contains(searchQuery, in: item.genre ?? "") else {
                    return false
                }
            }

            guard criteria.isEmpty == false else { return true }
            switch matchMode {
            case .all:
                return criteria.allSatisfy { LibrarySearchFilter.contains($0.query, in: $0.field.value(item)) }
            case .any:
                return criteria.contains { LibrarySearchFilter.contains($0.query, in: $0.field.value(item)) }
            }
        }
    }

    nonisolated fileprivate struct Criterion: Sendable {
        let query: String
        let field: Field
    }

    nonisolated fileprivate enum Field: Sendable {
        case title, album, artist, albumArtist, composer, genre

        func value<Item: LibraryListItemValues>(_ item: Item) -> String {
            switch self {
            case .title: item.title
            case .album: item.album
            case .artist: item.artist
            case .albumArtist: item.albumArtist ?? ""
            case .composer: item.composer ?? ""
            case .genre: item.genre ?? ""
            }
        }
    }

    private var activeCriteria: [Criterion] {
        [
            Criterion(query: normalized(title), field: .title),
            Criterion(query: normalized(album), field: .album),
            Criterion(query: normalized(artist), field: .artist),
            Criterion(query: normalized(albumArtist), field: .albumArtist),
            Criterion(query: normalized(composer), field: .composer),
            Criterion(query: normalized(genre), field: .genre)
        ].filter { $0.query.isEmpty == false }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contains(_ query: String, in value: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }
}

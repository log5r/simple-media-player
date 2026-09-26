import Foundation

enum LibraryFilterMatchMode: String, CaseIterable, Identifiable {
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

struct LibrarySearchFilter: Equatable {
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

    func matches(_ item: MediaItem, searchText: String = "") -> Bool {
        let searchQuery = normalized(searchText)
        if searchQuery.isEmpty == false {
            let searchableValues = [
                item.title,
                item.artist,
                item.album,
                item.albumArtist ?? "",
                item.composer ?? "",
                item.genre ?? ""
            ]
            guard searchableValues.contains(where: { contains(searchQuery, in: $0) }) else {
                return false
            }
        }

        let results = activeCriteria.map { criterion in
            contains(criterion.query, in: criterion.value(item))
        }

        guard results.isEmpty == false else { return true }
        switch matchMode {
        case .all:
            return results.allSatisfy { $0 }
        case .any:
            return results.contains(true)
        }
    }

    private var activeCriteria: [(query: String, value: (MediaItem) -> String)] {
        [
            (normalized(title), { $0.title }),
            (normalized(album), { $0.album }),
            (normalized(artist), { $0.artist }),
            (normalized(albumArtist), { $0.albumArtist ?? "" }),
            (normalized(composer), { $0.composer ?? "" }),
            (normalized(genre), { $0.genre ?? "" })
        ].filter { $0.query.isEmpty == false }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func contains(_ query: String, in value: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }
}

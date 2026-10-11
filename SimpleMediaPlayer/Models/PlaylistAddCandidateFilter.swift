import Foundation

nonisolated protocol PlaylistAddItemValues {
    var id: UUID { get }
    var title: String { get }
    var artist: String { get }
    var album: String { get }
    var genre: String? { get }
}

extension MediaItem: PlaylistAddItemValues {}

/// Selects the items that the Add Tracks sheet offers for a playlist.
///
/// Matching compares `localizedLowercase` values, so it ignores case but distinguishes diacritics.
/// `LibrarySearchFilter` ignores diacritics too, so the sheet does not reuse it.
nonisolated enum PlaylistAddCandidateFilter {
    /// Keeps the order of `items`, drops `excludedIDs`, and matches the query against
    /// the title, artist, album, and genre. An empty query matches every item.
    static func candidates<Item: PlaylistAddItemValues>(
        from items: [Item],
        excluding excludedIDs: Set<UUID>,
        searchText: String
    ) -> [Item] {
        guard Task.isCancelled == false else { return [] }
        // Lowercase the query once instead of once per item.
        let query = searchText.isEmpty ? nil : searchText.localizedLowercase
        var result: [Item] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard Task.isCancelled == false else { return [] }
            guard excludedIDs.contains(item.id) == false else { continue }
            guard let query else {
                result.append(item)
                continue
            }
            if item.title.localizedLowercase.contains(query)
                || item.artist.localizedLowercase.contains(query)
                || item.album.localizedLowercase.contains(query)
                || (item.genre ?? "").localizedLowercase.contains(query) {
                result.append(item)
            }
        }
        return result
    }
}

nonisolated struct PlaylistAddCandidateSnapshot: Sendable {
    struct Item: PlaylistAddItemValues, Sendable {
        let id: UUID
        let title: String
        let artist: String
        let album: String
        let genre: String?

        @MainActor init(item: MediaItem) {
            id = item.id
            title = item.title
            artist = item.artist
            album = item.album
            genre = item.genre
        }
    }

    let items: [Item]
    let excludedIDs: Set<UUID>
    let sourceGeneration: UInt64

    func identifiers(searchText: String) -> [UUID] {
        PlaylistAddCandidateFilter.candidates(
            from: items, excluding: excludedIDs, searchText: searchText
        ).map(\.id)
    }
}

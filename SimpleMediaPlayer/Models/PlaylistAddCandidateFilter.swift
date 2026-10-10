import Foundation

/// Selects the items that the Add Tracks sheet offers for a playlist.
///
/// Matching compares `localizedLowercase` values, so it ignores case but distinguishes diacritics.
/// `LibrarySearchFilter` ignores diacritics too, so the sheet does not reuse it.
nonisolated enum PlaylistAddCandidateFilter {
    /// Keeps the order of `items`, drops `excludedIDs`, and matches the query against
    /// the title, artist, album, and genre. An empty query matches every item.
    static func candidates<Item: LibraryListItemValues>(
        from items: [Item],
        excluding excludedIDs: Set<UUID>,
        searchText: String
    ) -> [Item] {
        guard searchText.isEmpty == false else {
            return items.filter { excludedIDs.contains($0.id) == false }
        }
        // Lowercase the query once instead of once per item.
        let query = searchText.localizedLowercase
        return items.filter { item in
            guard excludedIDs.contains(item.id) == false else { return false }
            return item.title.localizedLowercase.contains(query)
                || item.artist.localizedLowercase.contains(query)
                || item.album.localizedLowercase.contains(query)
                || (item.genre ?? "").localizedLowercase.contains(query)
        }
    }
}

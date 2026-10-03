import Foundation

/// The metadata used by list searches and ordering, without a dependency on SwiftData.
nonisolated protocol LibraryListItemValues {
    var id: UUID { get }
    var title: String { get }
    var artist: String { get }
    var album: String { get }
    var genre: String? { get }
    var albumArtist: String? { get }
    var composer: String? { get }
    var year: String? { get }
    var trackNumber: String? { get }
    var discNumber: String? { get }
    var duration: TimeInterval { get }
    var isVideo: Bool { get }
    var addedAt: Date { get }
    var fileName: String { get }
    var displayArtist: String { get }
    var displayAlbum: String { get }
    var displayGenre: String { get }
    var displayContentType: String { get }
}

extension MediaItem: LibraryListItemValues {}

nonisolated struct LibraryListItemSnapshot: LibraryListItemValues, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let genre: String?
    let albumArtist: String?
    let composer: String?
    let year: String?
    let trackNumber: String?
    let discNumber: String?
    let duration: TimeInterval
    let isVideo: Bool
    let addedAt: Date
    let fileName: String
    let displayArtist: String
    let displayAlbum: String
    let displayGenre: String
    let displayContentType: String

    @MainActor init(item: MediaItem) {
        id = item.id
        title = item.title
        artist = item.artist
        album = item.album
        genre = item.genre
        albumArtist = item.albumArtist
        composer = item.composer
        year = item.year
        trackNumber = item.trackNumber
        discNumber = item.discNumber
        duration = item.duration
        isVideo = item.isVideo
        addedAt = item.addedAt
        fileName = item.fileName
        displayArtist = item.displayArtist
        displayAlbum = item.displayAlbum
        displayGenre = item.displayGenre
        displayContentType = item.displayContentType
    }
}

nonisolated struct LibraryListRequest: Equatable, Sendable {
    var section: LibrarySection?
    var searchText = ""
    var searchFilter = LibrarySearchFilter()
    var sortField: LibrarySortField = .dateAdded
    var sortDirection: LibrarySortDirection = .ascending

    init(
        section: LibrarySection? = nil,
        searchText: String = "",
        searchFilter: LibrarySearchFilter = LibrarySearchFilter(),
        sortField: LibrarySortField = .dateAdded,
        sortDirection: LibrarySortDirection = .ascending
    ) {
        self.section = section
        self.searchText = searchText
        self.searchFilter = searchFilter
        self.sortField = sortField
        self.sortDirection = sortDirection
    }
}

nonisolated struct LibraryListPlaylistEntrySnapshot: Sendable {
    let id: UUID
    let sortIndex: Int
    let itemID: UUID?
}

nonisolated struct LibraryListResult: Sendable {
    let identifiers: [UUID]
    let entryIDs: [UUID?]?

    init(identifiers: [UUID], entryIDs: [UUID?]? = nil) {
        self.identifiers = identifiers
        self.entryIDs = entryIDs
    }
}

nonisolated struct LibraryListSnapshot: Sendable {
    let items: [LibraryListItemSnapshot]
    let playlistEntries: [LibraryListPlaylistEntrySnapshot]?
    let request: LibraryListRequest

    func with(request: LibraryListRequest) -> Self {
        Self(items: items, playlistEntries: playlistEntries, request: request)
    }

    func identifiers() -> [UUID] {
        guard Task.isCancelled == false else { return [] }
        let predicate = request.searchFilter.prepared(searchText: request.searchText)
        let matching = items.filter { item in
            Task.isCancelled == false
                && (playlistEntries != nil || matchesSection(item)) && predicate.matches(item)
        }
        guard Task.isCancelled == false else { return [] }
        if let playlistEntries {
            return orderedPlaylistIdentifiers(playlistEntries, matchingIDs: Set(matching.map(\.id)))
        }
        let sorted = try? request.sortField.sorted(
            matching, direction: request.sortDirection, cancellationCheck: { Task.isCancelled }
        )
        return sorted?.map(\.id) ?? []
    }

    /// Keep playlist entry identity alongside duplicate item IDs for deletion validation.
    func result(identifiers: [UUID]) -> LibraryListResult {
        guard let playlistEntries else { return LibraryListResult(identifiers: identifiers) }
        var groups: [UUID: [LibraryListPlaylistEntrySnapshot]] = [:]
        for entry in playlistEntries {
            if let itemID = entry.itemID { groups[itemID, default: []].append(entry) }
        }
        var orderedGroups: [UUID: [UUID]] = [:]
        var consumed: [UUID: Int] = [:]
        let entryIDs = identifiers.map { id -> UUID? in
            if orderedGroups[id] == nil {
                orderedGroups[id] = orderedPlaylistEntries(groups[id, default: []])?.map(\.id) ?? []
            }
            let index = consumed[id, default: 0]
            consumed[id] = index + 1
            guard let group = orderedGroups[id], group.indices.contains(index) else { return nil }
            return group[index]
        }
        return LibraryListResult(identifiers: identifiers, entryIDs: entryIDs)
    }

    private func orderedPlaylistIdentifiers(
        _ entries: [LibraryListPlaylistEntrySnapshot], matchingIDs: Set<UUID>
    ) -> [UUID] {
        guard let ordered = orderedPlaylistEntries(entries), Task.isCancelled == false else { return [] }
        return ordered.compactMap { entry in
            entry.itemID.flatMap { matchingIDs.contains($0) ? $0 : nil }
        }
    }

    private func orderedPlaylistEntries(
        _ entries: [LibraryListPlaylistEntrySnapshot]
    ) -> [LibraryListPlaylistEntrySnapshot]? {
        guard Task.isCancelled == false else { return nil }
        var comparisonsUntilCancellationCheck = 128
        return try? entries.sorted { lhs, rhs in
            comparisonsUntilCancellationCheck -= 1
            if comparisonsUntilCancellationCheck == 0 {
                if Task.isCancelled { throw CancellationError() }
                comparisonsUntilCancellationCheck = 128
            }
            if lhs.sortIndex == rhs.sortIndex { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.sortIndex < rhs.sortIndex
        }
    }

    private func matchesSection(_ item: LibraryListItemSnapshot) -> Bool {
        switch request.section {
        case nil: true
        case .allVideos: item.isVideo
        case .allSongs, .albums, .artists, .genres: item.isVideo == false
        }
    }
}

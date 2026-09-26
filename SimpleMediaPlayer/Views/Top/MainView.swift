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

struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaItem.addedAt) private var items: [MediaItem]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]

    let libraryService: LibraryService
    let player: PlayerViewModel
    @Binding var isImporterPresented: Bool

    @State private var selection: SidebarSelection = .library(.allSongs)
    @State private var searchText = ""
    @State private var searchFilter = LibrarySearchFilter()
    @State private var importErrorPresented = false
    @State private var addToPlaylistTarget: Playlist?
    @State private var selectedItemID: UUID?
    @State private var librarySortField: LibrarySortField = .dateAdded
    @State private var librarySortDirection: LibrarySortDirection = .ascending
    @State private var pendingExportPlan: MediaExportPlan?
    @State private var saveCopyTarget: MediaItem?
    @State private var exportResultPresented = false
    @State private var exportResultMessage = ""
    @State private var aacVersionExporter = TransformedTrackExporter()
    @State private var aacVersionSourceTitle: String?
    @State private var aacVersionResultPresented = false
    @State private var aacVersionResultMessage = ""
    @AppStorage("showLyricsPanel") private var showLyricsPanel = true

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(
                    selection: $selection,
                    playlists: playlists,
                    createPlaylist: { _ = createPlaylist() },
                    renamePlaylist: renamePlaylist,
                    deletePlaylist: deletePlaylist
                )
            } detail: {
                DetailAreaView(
                    items: filteredItems,
                    allQueue: filteredItems,
                    selectedSection: selectedSection,
                    activePlaylist: selectedPlaylist,
                    title: navigationTitle,
                    searchText: $searchText,
                    searchFilter: $searchFilter,
                    librarySortField: $librarySortField,
                    librarySortDirection: $librarySortDirection,
                    showLyricsPanel: $showLyricsPanel,
                    isImporterPresented: $isImporterPresented,
                    selectedItemID: $selectedItemID,
                    libraryService: libraryService,
                    player: player,
                    playlists: playlists,
                    addToPlaylist: addToPlaylist,
                    createPlaylistWithItem: createPlaylist(with:),
                    removeFromPlaylist: removeFromSelectedPlaylist,
                    movePlaylistItem: moveInSelectedPlaylist,
                    createAACVersion: createAACVersion,
                    canCreateAACVersion: canCreateAACVersion,
                    aacVersionExporter: aacVersionExporter,
                    aacVersionSourceTitle: aacVersionSourceTitle,
                    createPlaylist: { _ = createPlaylist() },
                    showAddToPlaylistSheet: {
                        if let selectedPlaylist {
                            addToPlaylistTarget = selectedPlaylist
                        }
                    },
                    exportToFinder: startFinderExport,
                    requestSaveCopy: { item in
                        saveCopyTarget = item
                    },
                    deleteItem: { item in
                        if player.currentItem?.id == item.id {
                            player.clearCurrentItem()
                        }
                        libraryService.delete(item, from: modelContext)
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .minFrame()

            SeekBarView(player: player)
            BottomPanelView(
                player: player,
                selectedItem: selectedItem,
                queue: filteredItems,
                playItem: { item in
                    player.play(item: item, in: filteredItems)
                },
                requestSaveCopy: { item in
                    saveCopyTarget = item
                }
            )
        }
        .fileImporter(
            isPresented: $isImporterPresented, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                startImport(urls)
            case let .failure(error):
                libraryService.lastImportErrors = [error.localizedDescription]
                importErrorPresented = true
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            startImport(urls, retainingSecurityScopedAccess: true)
            return true
        }
        .alert("Import Error", isPresented: $importErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(libraryService.lastImportErrors.joined(separator: "\n"))
        }
        .alert("Playback Error", isPresented: Binding(
            get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
        .alert("Export to Finder", isPresented: $exportResultPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportResultMessage)
        }
        .alert("Create AAC Version", isPresented: $aacVersionResultPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(aacVersionResultMessage)
        }
        .sheet(item: $addToPlaylistTarget) { playlist in
            PlaylistAddItemsView(playlist: playlist, items: items) { selectedItems in
                add(selectedItems, to: playlist)
            }
        }
        .sheet(item: $pendingExportPlan) { plan in
            ExportMissingTitlesView(plan: plan) { names in
                pendingExportPlan = nil
                continueFinderExport(plan: plan, nameOverrides: names)
            } cancel: {
                pendingExportPlan = nil
            }
        }
        .sheet(item: $saveCopyTarget) { item in
            SaveTransformedCopyView(
                item: item,
                player: player,
                libraryService: libraryService,
                modelContext: modelContext,
                onComplete: { _ in
                    saveCopyTarget = nil
                },
                onCancel: {
                    saveCopyTarget = nil
                }
            )
        }
    }

    private var selectedSection: LibrarySection? {
        if case let .library(section) = selection {
            section
        } else {
            nil
        }
    }

    private var selectedPlaylist: Playlist? {
        guard case let .playlist(id) = selection else { return nil }
        return playlists.first { $0.id == id }
    }

    private var navigationTitle: String {
        switch selection {
        case let .library(section):
            section.title
        case let .playlist(id):
            playlists.first { $0.id == id }?.name ?? L10n.string("Playlists")
        }
    }

    private var filteredItems: [MediaItem] {
        let filtered = baseItems.filter { searchFilter.matches($0, searchText: searchText) }

        guard selectedPlaylist == nil else { return filtered }
        return librarySortField.sorted(filtered, direction: librarySortDirection)
    }

    private var selectedItem: MediaItem? {
        guard let selectedItemID else { return nil }
        return filteredItems.first { $0.id == selectedItemID }
    }

    private var canCreateAACVersion: Bool {
        aacVersionSourceTitle == nil
            && aacVersionExporter.isExporting == false
            && libraryService.isImporting == false
            && libraryService.isExporting == false
    }

    private var baseItems: [MediaItem] {
        switch selection {
        case let .library(section):
            return items.filter { item in
                switch section {
                case .allSongs: item.isVideo == false
                case .allVideos: item.isVideo
                case .albums, .artists, .genres: item.isVideo == false
                }
            }
        case let .playlist(id):
            return playlists.first { $0.id == id }?.orderedItems ?? []
        }
    }

    private func startImport(_ urls: [URL], retainingSecurityScopedAccess: Bool = false) {
        let accessedURLs = retainingSecurityScopedAccess
            ? urls.filter { $0.startAccessingSecurityScopedResource() }
            : []

        Task {
            defer {
                accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            await libraryService.importFiles(from: urls, into: modelContext, existingItems: items)
            importErrorPresented = libraryService.lastImportErrors.isEmpty == false
        }
    }

    private func startFinderExport() {
        Task {
            let plan = await libraryService.makeExportPlan(for: filteredItems)
            guard plan.files.isEmpty == false else {
                exportResultMessage = plan.preparationErrors.isEmpty
                    ? L10n.string("No media selected for export.")
                    : plan.preparationErrors.joined(separator: "\n")
                exportResultPresented = true
                return
            }

            if plan.missingTitleFiles.isEmpty {
                continueFinderExport(plan: plan, nameOverrides: [:])
            } else {
                pendingExportPlan = plan
            }
        }
    }

    private func createAACVersion(of item: MediaItem) {
        guard item.isVideo == false, canCreateAACVersion else { return }

        aacVersionSourceTitle = item.title
        Task {
            defer { aacVersionSourceTitle = nil }

            do {
                _ = try await aacVersionExporter.export(
                    item: item,
                    title: item.title,
                    format: .aac,
                    pitchSemitones: 0,
                    rate: 1,
                    libraryService: libraryService,
                    context: modelContext
                )
                aacVersionResultMessage = L10n.format("Created an AAC version of “%@”.", item.title)
            } catch is CancellationError {
                return
            } catch {
                aacVersionResultMessage = L10n.format("Could not create AAC version: %@", error.localizedDescription)
            }

            aacVersionResultPresented = true
        }
    }

    private func continueFinderExport(plan: MediaExportPlan, nameOverrides: [UUID: String]) {
        Task {
            await exportToFinder(plan: plan, nameOverrides: nameOverrides)
        }
    }

    private func exportToFinder(plan: MediaExportPlan, nameOverrides: [UUID: String]) async {
        guard let destinationURL = chooseExportDirectory() else { return }
        let files = plan.resolvedFiles(nameOverrides: nameOverrides)
        let result = await libraryService.export(files: files, to: destinationURL)
        var messages: [String] = []

        if result.exportedCount > 0 {
            messages.append(L10n.format("Exported %d media files.", result.exportedCount))
        }
        messages.append(contentsOf: plan.preparationErrors)
        messages.append(contentsOf: result.errors)

        exportResultMessage = messages.isEmpty ? L10n.string("Export completed.") : messages.joined(separator: "\n")
        exportResultPresented = true
    }

    private func chooseExportDirectory() -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.string("Export")
        panel.message = L10n.string("Choose a folder to export media.")
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }

    @discardableResult
    private func createPlaylist() -> Playlist {
        let playlist = Playlist(name: uniquePlaylistName())
        modelContext.insert(playlist)
        save()
        selection = .playlist(playlist.id)
        return playlist
    }

    private func createPlaylist(with item: MediaItem) {
        let playlist = createPlaylist()
        add([item], to: playlist)
    }

    private func renamePlaylist(_ playlist: Playlist, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        playlist.name = trimmed
        save()
    }

    private func deletePlaylist(_ playlist: Playlist) {
        if selection == .playlist(playlist.id) {
            selection = .library(.allSongs)
        }
        modelContext.delete(playlist)
        save()
    }

    private func addToPlaylist(_ item: MediaItem, _ playlist: Playlist) {
        add([item], to: playlist)
    }

    private func add(_ newItems: [MediaItem], to playlist: Playlist) {
        var existingIDs = Set(playlist.entries.compactMap { $0.item?.id })
        var nextIndex = (playlist.entries.map(\.sortIndex).max() ?? -1) + 1

        for item in newItems where existingIDs.contains(item.id) == false {
            let entry = PlaylistEntry(sortIndex: nextIndex, playlist: playlist, item: item)
            playlist.entries.append(entry)
            modelContext.insert(entry)
            existingIDs.insert(item.id)
            nextIndex += 1
        }
        normalizeSortIndexes(for: playlist)
        save()
    }

    private func removeFromSelectedPlaylist(_ item: MediaItem) {
        guard let selectedPlaylist else { return }
        for entry in selectedPlaylist.entries where entry.item?.id == item.id {
            modelContext.delete(entry)
        }
        normalizeSortIndexes(for: selectedPlaylist)
        save()
    }

    private func moveInSelectedPlaylist(_ item: MediaItem, by offset: Int) {
        guard let selectedPlaylist else { return }
        var entries = selectedPlaylist.orderedEntries
        guard let sourceIndex = entries.firstIndex(where: { $0.item?.id == item.id }) else { return }
        let destinationIndex = sourceIndex + offset
        guard entries.indices.contains(destinationIndex) else { return }
        entries.swapAt(sourceIndex, destinationIndex)
        for (index, entry) in entries.enumerated() {
            entry.sortIndex = index
        }
        save()
    }

    private func normalizeSortIndexes(for playlist: Playlist) {
        for (index, entry) in playlist.orderedEntries.enumerated() {
            entry.sortIndex = index
        }
    }

    private func uniquePlaylistName() -> String {
        let baseName = L10n.string("New Playlist")
        let existingNames = Set(playlists.map(\.name))
        guard existingNames.contains(baseName) else { return baseName }

        var index = 2
        while existingNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            player.errorMessage = L10n.format("Could not save playlist: %@", error.localizedDescription)
        }
    }
}

extension Playlist {
    var orderedEntries: [PlaylistEntry] {
        entries.sorted { lhs, rhs in
            if lhs.sortIndex == rhs.sortIndex {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sortIndex < rhs.sortIndex
        }
    }

    var orderedItems: [MediaItem] {
        orderedEntries.compactMap(\.item)
    }

    func contains(_ item: MediaItem) -> Bool {
        entries.contains { $0.item?.id == item.id }
    }
}

private extension View {
    @ViewBuilder
    func minFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 900, minHeight: 430)
        #else
        self
        #endif
    }
}

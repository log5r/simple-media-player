import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct MediaListView: View {
    let items: [MediaItem]
    let queue: [MediaItem]
    let section: LibrarySection?
    let activePlaylist: Playlist?
    let playlists: [Playlist]
    let libraryService: LibraryService
    let player: PlayerViewModel
    @Binding var librarySortField: LibrarySortField
    @Binding var librarySortDirection: LibrarySortDirection
    let addToPlaylist: (MediaItem, Playlist) -> Void
    let createPlaylistWithItem: (MediaItem) -> Void
    let removeFromPlaylist: (MediaItem) -> Void
    let movePlaylistItem: (MediaItem, Int) -> Void
    let createAACVersion: (MediaItem) -> Void
    let canCreateAACVersion: Bool
    let deleteItem: (MediaItem) -> Void
    @Binding var selectedItemID: UUID?
    @Binding var isBulkEditMode: Bool
    let bulkSelection: BulkMediaSelectionState
    @Bindable var browsingState: LibraryBrowsingState

    @AppStorage(AppSettingsKey.mediaListColumnCustomization)
    var columnCustomization = TableColumnCustomization<MediaTableRow>()
    @AppStorage(AppSettingsKey.mediaListColumnOrder)
    var columnOrderRaw = AppSettingsDefault.mediaListColumnOrder
    @AppStorage(AppSettingsKey.mediaListVisibleColumns)
    var visibleColumnsRaw = AppSettingsDefault.mediaListVisibleColumns
    @State var tableSortOrder: [KeyPathComparator<MediaTableRow>] = []
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else if section == .albums {
                albumBrowser
            } else if let group = browsingState.group, group.section == section {
                VStack(spacing: 0) {
                    Button("Back to List", systemImage: "chevron.left") { browsingState.closeGroup() }
                        .accessibilityIdentifier("libraryGroupBackButton")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal)
                    mediaTable
                }
            } else if section?.isGrouped == true {
                groupedList
            } else {
                mediaTable
            }
        }
        .background(.background)
        .focusedSceneValue(\.mediaInfoCommandAction, selectedInfoCommandAction)
        .focusedSceneValue(\.aacVersionCommandAction, selectedAACVersionCommandAction)
        .onAppear {
            if selectedItemID == nil { syncSelectionToCurrentItem() }
        }
        .onChange(of: player.currentItem?.id) { _, _ in
            syncSelectionToCurrentItem()
        }
        .onChange(of: isBulkEditMode) { _, isEditing in
            if isEditing == false {
                syncSelectionToCurrentItem()
            }
        }
        .onChange(of: items.map(\.id)) { _, _ in
            if items.isEmpty == false,
               let selectedItemID, items.contains(where: { $0.id == selectedItemID }) == false {
                syncSelectionToCurrentItem()
            }
        }
        #if os(macOS)
        .sheet(isPresented: Binding(
            get: { browsingState.infoItem != nil }, set: { if $0 == false { browsingState.infoItem = nil } }
        )) {
            if let infoItem = browsingState.infoItem {
                MediaInfoView(item: infoItem, libraryService: libraryService)
            }
        }
        .alert(
            "Delete from Library?",
            isPresented: Binding(
                get: { browsingState.deleteConfirmationItem != nil },
                set: { if $0 == false { browsingState.deleteConfirmationItem = nil } }
            ),
            presenting: browsingState.deleteConfirmationItem
        ) { item in
            Button("Delete", role: .destructive) {
                deleteItem(item)
                browsingState.deleteConfirmationItem = nil
            }
            Button("Cancel", role: .cancel) {
                browsingState.deleteConfirmationItem = nil
            }
        } message: { item in
            Text(L10n.format("Delete “%@” from your library. This action cannot be undone.", item.title))
        }
        #endif
    }

    var albumBrowser: some View {
        AlbumBrowserView(
            items: items,
            player: player,
            selectedItemID: $selectedItemID,
            isBulkEditMode: $isBulkEditMode,
            bulkSelection: bulkSelection,
            browsingState: browsingState,
            itemMenu: { item in
                rowMenu(for: item)
            }
        )
    }

    var groupedList: some View {
        List(selection: tableInteractionSelection) {
            ForEach(groupedSections) { group in
                Section {
                    ForEach(group.rows) { row in
                        groupedRow(row)
                            .tag(row.id)
                            .id(row.id)
                            .modifier(LibraryScrollAnchorRow(id: row.id))
                    }
                } header: {
                    #if os(iOS)
                    Button(group.title) {
                        if let section { browsingState.openGroup(section: section, name: group.title) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("libraryGroup.\(section?.rawValue ?? "").\(group.title)")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    #else
                    Text(group.title)
                    #endif
                }
            }
        }
        .listStyle(.inset)
        .modifier(LibraryScrollAnchor(itemIDs: rows.map(\.id), browsingState: browsingState))
    }

    var rows: [MediaTableRow] {
        let displayedItems = browsingState.group.flatMap { group in
            group.section == section ? items.filter(group.contains) : nil
        } ?? items
        return displayedItems.enumerated().map { offset, item in
            MediaTableRow(index: offset + 1, item: item)
        }
    }

    var selectedInfoCommandAction: MediaInfoCommandAction? {
        guard isBulkEditMode == false, selectedItem != nil else { return nil }
        return MediaInfoCommandAction {
            showInfoForSelectedItem()
        }
    }

    var selectedAACVersionCommandAction: AACVersionCommandAction? {
        guard isBulkEditMode == false,
              let selectedItem,
              selectedItem.isVideo == false,
              canCreateAACVersion
        else { return nil }

        return AACVersionCommandAction {
            createAACVersion(selectedItem)
        }
    }

    var tableInteractionSelection: Binding<Set<UUID>> {
        Binding {
            if isBulkEditMode {
                return []
            }
            return selectedItemID.map { Set([$0]) } ?? []
        } set: { newSelection in
            guard isBulkEditMode == false else { return }
            selectedItemID = newSelection.first
        }
    }

    var selectedItem: MediaItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID && browsingState.group?.contains($0) != false }
    }

    var emptyState: some View {
        ContentUnavailableView(
            activePlaylist == nil ? L10n.string("No Media") : L10n.string("Playlist is Empty"),
            systemImage: activePlaylist == nil ? "tray.and.arrow.down" : "music.note.list",
            description: Text(
                activePlaylist == nil
                    ? L10n.string("Import files or drag and drop them here.")
                    : L10n.string("Use the toolbar add button or a track menu to add items.")
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupedSections: [GroupedMediaSection] {
        let groupedRows = Dictionary(grouping: rows) { row in
            groupTitle(for: row.item)
        }

        return groupedRows.keys.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        .map { title in
            GroupedMediaSection(
                title: title,
                rows: groupedRows[title] ?? []
            )
        }
    }

}

private struct GroupedMediaSection: Identifiable {
    let title: String
    let rows: [MediaTableRow]

    var id: String {
        title
    }
}

private extension LibrarySection {
    var isGrouped: Bool {
        switch self {
        case .albums, .artists, .genres:
            true
        case .allSongs, .allVideos:
            false
        }
    }
}

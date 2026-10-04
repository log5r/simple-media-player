#if os(iOS)
import SwiftUI

struct IPhoneTrackListView: View {
    let items: [MediaItem]
    let section: LibrarySection?
    let playlist: Playlist?
    let title: String
    let playlists: [Playlist]
    let player: PlayerViewModel
    let libraryService: LibraryService
    let canCreateAACVersion: Bool
    let actions: IPhoneLibraryActions
    let play: (MediaItem, [MediaItem], String) -> Void
    let allItems: [MediaItem]
    var searchText = ""
    var searchFilter = LibrarySearchFilter()
    @Bindable var browsingState: LibraryBrowsingState
    var group: LibraryBrowsingGroup?
    @Binding var showsDeck: Bool

    @State var listProjection = LibraryListProjection()

    var body: some View {
        Group {
            if let section, isCategoryBrowser {
                categoryList(section)
            } else {
                trackList
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if playlist != nil {
                        Button("Add Tracks", systemImage: "plus") {
                            if let playlist { actions.showAddTracks(playlist) }
                        }
                            .disabled(!canCreateAACVersion)
                    }
                    if browsingState.isBulkEditMode {
                        Button("Done") { endEditing() }
                    } else {
                        Menu("More", systemImage: "ellipsis") {
                            if !isCategoryBrowser {
                                Button("Select", systemImage: "checklist") { browsingState.isBulkEditMode = true }
                                    .disabled(orderedItems.isEmpty || !canCreateAACVersion)
                                    .accessibilityIdentifier("multipleEditButton")
                            }
                            if playlist == nil && !isCategoryBrowser {
                                Picker("Sort By", selection: $browsingState.sortField) {
                                    ForEach(LibrarySortField.allCases) { field in Text(field.title).tag(field) }
                                }
                                Picker("Sort Direction", selection: $browsingState.sortDirection) {
                                    ForEach(LibrarySortDirection.allCases) { direction in
                                        Text(direction.title).tag(direction)
                                    }
                                }
                            }
                            Button("Export…", systemImage: "square.and.arrow.up") { actions.exportItems(orderedItems) }
                                .disabled(orderedItems.isEmpty || !canCreateAACVersion)
                        }
                        .accessibilityIdentifier("phoneTrackMore")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if browsingState.isBulkEditMode {
                Button("Edit Selected", systemImage: "pencil") {
                    guard selectedBulkItems.isEmpty == false else { return }
                    browsingState.bulkEditSession = BulkMetadataEditSession(items: selectedBulkItems)
                    browsingState.isBulkEditMode = false
                }
                    .disabled(selectedBulkItems.isEmpty || !canCreateAACVersion)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("editSelectedMediaButton")
                    .accessibilityValue("\(selectedBulkItems.count)")
            }
        }
        .modifier(LibraryListUpdates(
            projection: listProjection, items: items, playlist: playlist,
            request: LibraryListRequest(
                section: section, searchText: searchText, searchFilter: searchFilter,
                sortField: browsingState.sortField, sortDirection: browsingState.sortDirection
            )
        ))
        .onChange(of: items.map(\.id)) { _, ids in
            browsingState.bulkSelection.retain(ids: Set(ids))
        }
        .background {
            if isCompactCommandDestination {
                CompactLibraryCommandValues(
                    actions: compactCommands.appMenuActions,
                    info: selectedInfoCommandAction, aac: selectedAACVersionCommandAction
                )
            }
        }
    }

    var isCategoryBrowser: Bool {
        group == nil && (section.map { [LibrarySection.albums, .artists, .genres].contains($0) } ?? false)
    }

    var orderedItems: [MediaItem] {
        if let group { return group.playbackQueue(from: listProjection.items) }
        return listProjection.items
    }

    private var selectedBulkItems: [MediaItem] {
        orderedItems.filter { browsingState.bulkSelection.contains($0.id) }
    }

    private var trackPlaybackState: String {
        if player.isPlaying { return L10n.string("Playing") }
        return player.isPaused ? L10n.string("Paused") : L10n.string("Stopped")
    }

    private var trackList: some View {
        List {
            ForEach(orderedItems) { item in
                Button {
                    if browsingState.isBulkEditMode {
                        browsingState.bulkSelection.toggle(item.id)
                    } else {
                        play(item, orderedItems, title)
                    }
                } label: {
                    HStack(spacing: 12) {
                        if browsingState.isBulkEditMode {
                            Image(systemName: browsingState.bulkSelection.contains(item.id)
                                  ? "checkmark.circle.fill" : "circle")
                        }
                        LibraryItemArtworkView(item: item)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).foregroundStyle(.primary).lineLimit(1)
                            Text(item.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if player.currentItem?.id == item.id {
                            Image(systemName: "speaker.wave.2.fill").accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("phoneTrack.\(item.id)")
                .accessibilityValue(player.currentItem?.id == item.id ? trackPlaybackState : "")
                .accessibilityAddTraits(browsingState.bulkSelection.contains(item.id) ? .isSelected : [])
                .id(item.id)
                .modifier(LibraryScrollAnchorRow(id: item.id))
                .contextMenu { trackMenu(item) }
                .swipeActions {
                    Button("Delete from Library", systemImage: "trash", role: .destructive) {
                        browsingState.deleteConfirmationItem = item
                    }
                    if let playlist {
                        Button("Remove from Playlist", systemImage: "minus.circle") {
                            actions.removeItem(item, playlist)
                        }
                    }
                }
            }
            .onMove { source, destination in
                if let playlist, canReorderPlaylist { actions.moveItems(source, destination, playlist) }
            }
            .onDelete { offsets in
                let targets = offsets.map { orderedItems[$0] }
                if let playlist {
                    targets.forEach { actions.removeItem($0, playlist) }
                } else {
                    browsingState.deleteConfirmationItem = targets.first
                }
            }
            .moveDisabled(canReorderPlaylist == false)
        }
        .environment(\.editMode, Binding(
            get: { browsingState.isBulkEditMode ? .active : .inactive },
            set: { browsingState.isBulkEditMode = $0.isEditing }
        ))
        .modifier(LibraryScrollAnchor(itemIDs: orderedItems.map(\.id), browsingState: browsingState))
        .overlay {
            if orderedItems.isEmpty { ContentUnavailableView("No Media", systemImage: "music.note") }
        }
    }

    private func categoryList(_ section: LibrarySection) -> some View {
        let groups = Dictionary(grouping: orderedItems) { item in
            switch section {
            case .albums: item.displayAlbum
            case .artists: item.displayArtist
            default: item.displayGenre
            }
        }
        return List(groups.keys.sorted(), id: \.self) { name in
            NavigationLink(value: LibraryBrowsingRoute.group(LibraryBrowsingGroup(section: section, name: name))) {
                HStack {
                    Label(name, systemImage: section.icon)
                    Spacer()
                    Text("\(groups[name]?.count ?? 0)").foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            }
            .accessibilityIdentifier("libraryGroup.\(section.rawValue).\(name)")
        }
    }

    @ViewBuilder private func trackMenu(_ item: MediaItem) -> some View {
        Button("Get Info", systemImage: "info.circle") { browsingState.infoItem = item }
        Button("Create AAC Version", systemImage: "waveform.badge.plus") { actions.createAACVersion(item) }
            .disabled(item.isVideo || !canCreateAACVersion)
        Menu("Add to Playlist", systemImage: "music.note.list") {
            ForEach(playlists) { playlist in
                Button(playlist.name) { actions.addToPlaylist(item, playlist) }
                    .disabled(playlist.contains(item))
            }
            Button("New Playlist", systemImage: "plus") { actions.createPlaylistWithItem(item) }
        }
        if let playlist, let index = playlist.orderedItems.firstIndex(where: { $0.id == item.id }) {
            Button("Move Up", systemImage: "arrow.up") {
                actions.moveItems(IndexSet(integer: index), index - 1, playlist)
            }.disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") {
                actions.moveItems(IndexSet(integer: index), index + 2, playlist)
            }.disabled(index == playlist.orderedItems.count - 1)
            Button("Remove from Playlist", systemImage: "minus.circle") {
                actions.removeItem(item, playlist)
            }
        }
        Button("Delete from Library", systemImage: "trash", role: .destructive) {
            browsingState.deleteConfirmationItem = item
        }
    }

    private func endEditing() {
        browsingState.endEditing()
    }

    private var canReorderPlaylist: Bool {
        guard let playlist, searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              searchFilter.isActive == false else { return false }
        // The displayed projection may still be completing a previous filter request.
        return orderedItems.map(\.id) == playlist.orderedItems.map(\.id)
    }
}
#endif

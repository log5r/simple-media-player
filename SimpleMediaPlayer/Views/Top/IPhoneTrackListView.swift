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

    @State private var sortField = LibrarySortField.dateAdded
    @State private var sortDirection = LibrarySortDirection.ascending
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<UUID>()
    @State private var infoItem: MediaItem?
    @State private var deleteItem: MediaItem?
    @State private var showsBulkEditor = false
    @State private var showsAddTracks = false

    var body: some View {
        Group {
            if let section, [LibrarySection.albums, .artists, .genres].contains(section) {
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
                        Button("Add Tracks", systemImage: "plus") { showsAddTracks = true }
                            .disabled(!canCreateAACVersion)
                    }
                    if editMode.isEditing {
                        Button("Done") { endEditing() }
                    } else {
                        Menu("More", systemImage: "ellipsis") {
                            if !isCategoryBrowser {
                                Button("Select", systemImage: "checklist") { editMode = .active }
                                    .disabled(items.isEmpty || !canCreateAACVersion)
                                    .accessibilityIdentifier("multipleEditButton")
                            }
                            if playlist == nil && !isCategoryBrowser {
                                Picker("Sort By", selection: $sortField) {
                                    ForEach(LibrarySortField.allCases) { field in Text(field.title).tag(field) }
                                }
                                Picker("Sort Direction", selection: $sortDirection) {
                                    ForEach(LibrarySortDirection.allCases) { direction in
                                        Text(direction.title).tag(direction)
                                    }
                                }
                            }
                            Button("Export…", systemImage: "square.and.arrow.up") { actions.exportItems(orderedItems) }
                                .disabled(items.isEmpty || !canCreateAACVersion)
                        }
                        .accessibilityIdentifier("phoneTrackMore")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                Button("Edit Selected", systemImage: "pencil") { showsBulkEditor = true }
                    .disabled(selection.isEmpty || !canCreateAACVersion)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("editSelectedMediaButton")
                    .accessibilityValue("\(selection.count)")
            }
        }
        .sheet(item: $infoItem) { item in MediaInfoView(item: item, libraryService: libraryService) }
        .sheet(isPresented: $showsBulkEditor, onDismiss: endEditing) {
            BulkMetadataEditView(items: items.filter { selection.contains($0.id) }, libraryService: libraryService)
        }
        .sheet(isPresented: $showsAddTracks) {
            if let playlist {
                PlaylistAddItemsView(playlist: playlist, items: allItems) { actions.addItems($0, playlist) }
            }
        }
        .alert("Delete from Library?", isPresented: Binding(
            get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }
        ), presenting: deleteItem) { item in
            Button("Delete", role: .destructive) { actions.deleteItem(item); deleteItem = nil }
            Button("Cancel", role: .cancel) { deleteItem = nil }
        } message: { item in
            Text(L10n.format("Delete “%@” from your library. This action cannot be undone.", item.title))
        }
        .onChange(of: items.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }

    private var isCategoryBrowser: Bool {
        section.map { [LibrarySection.albums, .artists, .genres].contains($0) } ?? false
    }

    private var orderedItems: [MediaItem] {
        playlist == nil ? sortField.sorted(items, direction: sortDirection) : items
    }

    private var trackList: some View {
        List {
            ForEach(orderedItems) { item in
                Button {
                    if editMode.isEditing {
                        if !selection.insert(item.id).inserted { selection.remove(item.id) }
                    } else {
                        play(item, orderedItems, title)
                    }
                } label: {
                    HStack(spacing: 12) {
                        if editMode.isEditing {
                            Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        }
                        ArtworkView(data: item.artworkData, isVideo: item.isVideo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).foregroundStyle(.primary).lineLimit(1)
                            Text(item.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if player.currentItem?.id == item.id {
                            Image(systemName: "speaker.wave.2.fill").accessibilityLabel("Playing")
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("phoneTrack.\(item.id)")
                .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
                .contextMenu { trackMenu(item) }
                .swipeActions {
                    Button("Delete from Library", systemImage: "trash", role: .destructive) { deleteItem = item }
                    if let playlist {
                        Button("Remove from Playlist", systemImage: "minus.circle") {
                            actions.removeItem(item, playlist)
                        }
                    }
                }
            }
            .onMove { source, destination in
                if let playlist { actions.moveItems(source, destination, playlist) }
            }
            .onDelete { offsets in
                let targets = offsets.map { orderedItems[$0] }
                if let playlist {
                    targets.forEach { actions.removeItem($0, playlist) }
                } else {
                    deleteItem = targets.first
                }
            }
            .moveDisabled(playlist == nil)
        }
        .environment(\.editMode, $editMode)
        .overlay {
            if items.isEmpty { ContentUnavailableView("No Media", systemImage: "music.note") }
        }
    }

    private func categoryList(_ section: LibrarySection) -> some View {
        let groups = Dictionary(grouping: items) { item in
            switch section {
            case .albums: item.displayAlbum
            case .artists: item.displayArtist
            default: item.displayGenre
            }
        }
        return List(groups.keys.sorted(), id: \.self) { name in
            NavigationLink {
                IPhoneTrackListView(
                    items: groups[name] ?? [], section: nil, playlist: nil, title: name,
                    playlists: playlists, player: player, libraryService: libraryService,
                    canCreateAACVersion: canCreateAACVersion, actions: actions, play: play, allItems: allItems
                )
            } label: {
                HStack {
                    Label(name, systemImage: section.icon)
                    Spacer()
                    Text("\(groups[name]?.count ?? 0)").foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder private func trackMenu(_ item: MediaItem) -> some View {
        Button("Get Info", systemImage: "info.circle") { infoItem = item }
        Button("Create AAC Version", systemImage: "waveform.badge.plus") { actions.createAACVersion(item) }
            .disabled(item.isVideo || !canCreateAACVersion)
        Menu("Add to Playlist", systemImage: "music.note.list") {
            ForEach(playlists) { playlist in
                Button(playlist.name) { actions.addToPlaylist(item, playlist) }
                    .disabled(playlist.contains(item))
            }
            Button("New Playlist", systemImage: "plus") { actions.createPlaylistWithItem(item) }
        }
        if let playlist, let index = items.firstIndex(where: { $0.id == item.id }) {
            Button("Move Up", systemImage: "arrow.up") {
                actions.moveItems(IndexSet(integer: index), index - 1, playlist)
            }.disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") {
                actions.moveItems(IndexSet(integer: index), index + 2, playlist)
            }.disabled(index == items.count - 1)
            Button("Remove from Playlist", systemImage: "minus.circle") {
                actions.removeItem(item, playlist)
            }
        }
        Button("Delete from Library", systemImage: "trash", role: .destructive) { deleteItem = item }
    }

    private func endEditing() {
        editMode = .inactive
        selection.removeAll()
    }
}
#endif

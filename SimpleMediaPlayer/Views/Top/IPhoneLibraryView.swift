import SwiftUI

#if os(iOS)
import SwiftData
import UIKit

struct IPhoneLibraryActions {
    let createPlaylist: () -> Playlist
    let renamePlaylist: (Playlist, String) -> Void
    let deletePlaylist: (Playlist) -> Void
    let addToPlaylist: (MediaItem, Playlist) -> Void
    let createPlaylistWithItem: (MediaItem) -> Void
    let addItems: ([MediaItem], Playlist) -> Void
    let removeItem: (MediaItem, Playlist) -> Void
    let moveItems: (IndexSet, Int, Playlist) -> Void
    let createAACVersion: (MediaItem) -> Void
    let exportItems: ([MediaItem]) -> Void
    let deleteItem: (MediaItem) -> Void
    let showAddTracks: (Playlist) -> Void
}

struct IPhoneLibraryView: View {
    let items: [MediaItem]
    let playlists: [Playlist]
    let player: PlayerViewModel
    let libraryService: LibraryService
    @Binding var isImporterPresented: Bool
    @Binding var showsDeck: Bool
    @Binding var aacResultMessage: String
    @Binding var showsAACResult: Bool
    let canCreateAACVersion: Bool
    let aacVersionExporter: TransformedTrackExporter
    let actions: IPhoneLibraryActions
    @Bindable var browsingState: LibraryBrowsingState

    var body: some View {
        TabView(selection: Binding(get: { browsingState.phoneTab }, set: browsingState.selectPhoneTab)) {
            Tab("Library", systemImage: "music.note.house", value: 0) {
                NavigationStack(path: Binding(
                    get: { browsingState.libraryPath }, set: browsingState.navigateLibrary
                )) {
                    List(LibrarySection.allCases.filter { $0 != .allVideos }) { section in
                        NavigationLink(value: LibraryBrowsingRoute.section(section)) {
                            Label(section.title, systemImage: section.icon)
                                .frame(minHeight: 44)
                        }
                    }
                    .navigationTitle("Library")
                    .toolbar { libraryMenu }
                    .navigationDestination(for: LibraryBrowsingRoute.self) { route in
                        switch route {
                        case let .section(section):
                            trackList(section: section, title: section.title)
                        case let .group(group):
                            trackList(section: group.section, title: group.name, group: group)
                        }
                    }
                }
            }
            Tab("Playlists", systemImage: "music.note.list", value: 1) {
                NavigationStack(path: Binding(
                    get: { browsingState.playlistPath }, set: browsingState.navigatePlaylists
                )) {
                    playlistList
                        .navigationDestination(for: UUID.self) { id in
                            if let playlist = playlists.first(where: { $0.id == id }) {
                                trackList(section: nil, playlist: playlist, title: playlist.name)
                            }
                        }
                }
            }
            Tab("Videos", systemImage: "film", value: 2) {
                NavigationStack {
                    trackList(section: .allVideos, title: L10n.string("All Videos"))
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: 3, role: .search) {
                NavigationStack {
                    trackList(section: nil, title: L10n.string("Search"), isSearch: true)
                        .searchable(text: $browsingState.searchText, prompt: "Search")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Filters", systemImage: browsingState.searchFilter.isActive
                                       ? "line.3.horizontal.decrease.circle.fill"
                                       : "line.3.horizontal.decrease.circle") {
                                    browsingState.showsFilters = true
                                }
                                .accessibilityIdentifier("advancedSearchButton")
                            }
                        }
                }
            }
        }
        .tabBarMinimizeBehavior(.never)
        .tabViewBottomAccessory(isEnabled: player.currentItem != nil) {
            IPhoneLEDDock(player: player) { showsDeck = true }
        }
        .overlay(alignment: .top) { progressPanel }
        .onChange(of: player.currentItem?.id) { _, id in
            if id == nil { showsDeck = false }
        }
    }

    private var libraryMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                Button("Import...", systemImage: "square.and.arrow.down") { isImporterPresented = true }
                    .disabled(libraryService.isImporting || aacVersionExporter.isExporting)
                    .accessibilityIdentifier("importMediaButton")
                Button("Export…", systemImage: "square.and.arrow.up") { actions.exportItems(items) }
                    .disabled(items.isEmpty || !canCreateAACVersion)
                Button("Settings", systemImage: "gearshape") { browsingState.showsSettings = true }
                    .accessibilityIdentifier("settingsButton")
            }
            .accessibilityIdentifier("phoneLibraryMore")
        }
    }

    private var playlistList: some View {
        List {
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist.id) {
                    Label(playlist.name, systemImage: "music.note.list").frame(minHeight: 44)
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        browsingState.nameDraft = playlist.name
                        browsingState.playlistToRename = playlist
                    }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                        browsingState.playlistToDelete = playlist
                    }
                }
            }
            Button("Add Playlist", systemImage: "plus.circle") {
                let playlist = actions.createPlaylist()
                browsingState.navigatePlaylists(to: [playlist.id])
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("addPlaylistButton")
        }
        .navigationTitle("Playlists")
    }

    private func trackList(
        section: LibrarySection?, playlist: Playlist? = nil, title: String,
        group: LibraryBrowsingGroup? = nil, isSearch: Bool = false
    ) -> some View {
        return IPhoneTrackListView(
            items: items, section: section, playlist: playlist, title: title,
            playlists: playlists, player: player, libraryService: libraryService,
            canCreateAACVersion: canCreateAACVersion, actions: actions,
            play: { item, queue, playingTitle in
                browsingState.playingListName = playingTitle
                browsingState.selectedItemID = item.id
                player.play(item: item, in: queue)
            }, allItems: items,
            searchText: isSearch ? browsingState.searchText : "",
            searchFilter: isSearch ? browsingState.searchFilter : LibrarySearchFilter(),
            browsingState: browsingState, group: group
        )
    }

    @ViewBuilder private var progressPanel: some View {
        if libraryService.isImporting || libraryService.isExporting || aacVersionExporter.isExporting {
            VStack(spacing: 8) {
                if libraryService.isImporting {
                    Text("Importing")
                    ProgressView(value: libraryService.importProgress)
                } else if libraryService.isExporting {
                    Text("Exporting")
                    ProgressView(value: libraryService.exportProgress)
                } else {
                    Text("Create AAC Version")
                    ProgressView(value: aacVersionExporter.progress)
                }
            }
            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
        }
    }
}
#endif

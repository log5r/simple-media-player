import SwiftUI

extension EnvironmentValues {
    @Entry var usesPhoneLayout = false
}

extension View {
    func platformEditorFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
        modifier(PlatformEditorFrame(width: width, height: height))
    }
}

private struct PlatformEditorFrame: ViewModifier {
    let width: CGFloat
    let height: CGFloat?
    @Environment(\.usesPhoneLayout) private var usesPhoneLayout

    func body(content: Content) -> some View {
        content.frame(width: usesPhoneLayout ? nil : width, height: usesPhoneLayout ? nil : height)
    }
}

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
    let createAACVersionWithResult: (MediaItem, @escaping (String) -> Void) -> Void
    let exportItems: ([MediaItem]) -> Void
    let deleteItem: (MediaItem) -> Void
}

struct IPhoneLibraryView: View {
    let items: [MediaItem]
    let playlists: [Playlist]
    let player: PlayerViewModel
    let libraryService: LibraryService
    @Binding var isImporterPresented: Bool
    let canCreateAACVersion: Bool
    let aacVersionExporter: TransformedTrackExporter
    let actions: IPhoneLibraryActions

    @State private var tab = 0
    @State private var searchText = ""
    @State private var searchFilter = LibrarySearchFilter()
    @State private var showsFilters = false
    @State private var showsSettings = false
    @State private var showsDeck = false
    @State private var playlistToRename: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var nameDraft = ""
    @State private var playlistPath: [UUID] = []
    @State private var playingListName = L10n.string("All Songs")

    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "music.note.house", value: 0) {
                NavigationStack {
                    List(LibrarySection.allCases.filter { $0 != .allVideos }) { section in
                        NavigationLink {
                            trackList(section: section, title: section.title)
                        } label: {
                            Label(section.title, systemImage: section.icon)
                                .frame(minHeight: 44)
                        }
                    }
                    .navigationTitle("Library")
                    .toolbar { libraryMenu }
                }
            }
            Tab("Playlists", systemImage: "music.note.list", value: 1) {
                NavigationStack(path: $playlistPath) {
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
                        .searchable(text: $searchText, prompt: "Search")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Filters", systemImage: searchFilter.isActive
                                       ? "line.3.horizontal.decrease.circle.fill"
                                       : "line.3.horizontal.decrease.circle") {
                                    showsFilters = true
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
        .fullScreenCover(isPresented: $showsDeck) {
            IPhoneDeckView(
                player: player, libraryService: libraryService, listName: playingListName,
                canCreateAACVersion: canCreateAACVersion, createAACVersion: actions.createAACVersionWithResult
            )
        }
        .sheet(isPresented: $showsSettings) { AppSettingsView(player: player) }
        .sheet(isPresented: $showsFilters) { AdvancedSearchView(filter: $searchFilter) }
        .alert("Rename Playlist", isPresented: Binding(
            get: { playlistToRename != nil }, set: { if !$0 { playlistToRename = nil } }
        )) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let playlistToRename { actions.renamePlaylist(playlistToRename, nameDraft) }
                playlistToRename = nil
            }
            Button("Cancel", role: .cancel) { playlistToRename = nil }
        }
        .alert("Delete Playlist?", isPresented: Binding(
            get: { playlistToDelete != nil }, set: { if !$0 { playlistToDelete = nil } }
        ), presenting: playlistToDelete) { playlist in
            Button("Delete", role: .destructive) {
                playlistPath.removeAll { $0 == playlist.id }
                actions.deletePlaylist(playlist)
                playlistToDelete = nil
            }
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
        } message: { playlist in
            Text(L10n.format("Delete “%@”? Media files in your library will not be deleted.", playlist.name))
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
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
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
                        nameDraft = playlist.name
                        playlistToRename = playlist
                    }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                        playlistToDelete = playlist
                    }
                }
            }
            Button("Add Playlist", systemImage: "plus.circle") {
                let playlist = actions.createPlaylist()
                playlistPath.append(playlist.id)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("addPlaylistButton")
        }
        .navigationTitle("Playlists")
    }

    private func trackList(
        section: LibrarySection?, playlist: Playlist? = nil, title: String, isSearch: Bool = false
    ) -> some View {
        let source = playlist?.orderedItems ?? items.filter {
            isSearch || (section == .allVideos ? $0.isVideo : !$0.isVideo)
        }
        let filtered = isSearch ? source.filter { searchFilter.matches($0, searchText: searchText) } : source
        return IPhoneTrackListView(
            items: filtered, section: section, playlist: playlist, title: title,
            playlists: playlists, player: player, libraryService: libraryService,
            canCreateAACVersion: canCreateAACVersion, actions: actions,
            play: { item, queue, playingTitle in
                playingListName = playingTitle
                player.play(item: item, in: queue)
            }, allItems: items
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

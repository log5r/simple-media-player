import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct MainView: View {
    @Environment(\.modelContext) var modelContext
    @Query(sort: \MediaItem.addedAt) var items: [MediaItem]
    @Query(sort: \Playlist.createdAt) var playlists: [Playlist]

    let libraryService: LibraryService
    let player: PlayerViewModel
    @Binding var isImporterPresented: Bool

    @State var selection: SidebarSelection = .library(.allSongs)
    @State var searchText = LibraryListUITestFixture.searchText
    @State var searchFilter = LibrarySearchFilter()
    @State var importErrorPresented = false
    @State var addToPlaylistTarget: Playlist?
    @State var selectedItemID: UUID?
    @State var librarySortField: LibrarySortField = .dateAdded
    @State var librarySortDirection: LibrarySortDirection = .ascending
    @State var listProjection = LibraryListProjection()
    @State var isPreparingExport = false
    @State var pendingExportPlan: MediaExportPlan?
    @State var namedExportRequest: (plan: MediaExportPlan, names: [UUID: String])?
    @State var saveCopyTarget: MediaItem?
    @State var exportResultPresented = false
    @State var exportResultMessage = ""
    @State var aacVersionExporter = MainView.makeAACVersionExporter()
    @State var aacVersionSourceTitle: String?
    @State var aacVersionResultPresented = false
    @State var aacVersionResultMessage = ""
    @AppStorage("showLyricsPanel") var showLyricsPanel = true

    #if os(iOS)
    @State var phoneExportSheet: IPhoneExportSheet?
    @State var showsExportErrorsAfterSharing = false
    @State var isPhoneDeckPresented = false
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                phoneView
                    .environment(\.usesPhoneLayout, true)
            } else {
                desktopView
            }
            #else
            desktopView
            #endif
        }
        .fileImporter(
            isPresented: $isImporterPresented, allowedContentTypes: [.movie, .data], allowsMultipleSelection: true
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
        .alert(
            usesPhoneLayout ? L10n.string("Export") : L10n.string("Export to Finder"),
            isPresented: $exportResultPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportResultMessage)
        }
        .alert("Create AAC Version", isPresented: aacResultPresentation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(aacVersionResultMessage)
        }
        #if os(iOS)
        .sheet(item: $phoneExportSheet, onDismiss: finishExportSheet) { sheet in
            switch sheet {
            case let .names(plan):
                exportNamesView(plan)
            case let .share(export):
                IPhoneShareSheet(export: export)
            }
        }
        #endif
        .sheet(item: $addToPlaylistTarget) { playlist in
            PlaylistAddItemsView(playlist: playlist, items: items) { selectedItems in
                add(selectedItems, to: playlist)
            }
        }
        #if os(macOS)
        .sheet(item: $pendingExportPlan, onDismiss: finishExportSheet) { plan in
            exportNamesView(plan)
        }
        #endif
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
        .environment(\.usesPhoneLayout, usesPhoneLayout)
    }

    private func exportNamesView(_ plan: MediaExportPlan) -> some View {
        ExportMissingTitlesView(plan: plan) { names in
            namedExportRequest = (plan, names)
            closeExportNames()
        } cancel: {
            namedExportRequest = nil
            closeExportNames()
        }
    }

    private func closeExportNames() {
        #if os(iOS)
        phoneExportSheet = nil
        #else
        pendingExportPlan = nil
        #endif
    }

    private func finishExportSheet() {
        if let request = namedExportRequest {
            namedExportRequest = nil
            continueFinderExport(plan: request.plan, nameOverrides: request.names)
        } else {
            #if os(iOS)
            if showsExportErrorsAfterSharing {
                showsExportErrorsAfterSharing = false
                exportResultPresented = true
            }
            #endif
        }
    }

    private var usesPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

}

extension MainView {
    var desktopView: some View {
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
                        deleteLibraryItem(item)
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
        .modifier(LibraryListUpdates(
            projection: listProjection,
            items: items,
            playlist: selectedPlaylist,
            request: LibraryListRequest(
                section: selectedSection,
                searchText: searchText,
                searchFilter: searchFilter,
                sortField: librarySortField,
                sortDirection: librarySortDirection
            )
        ))
    }

    #if os(iOS)
    var phoneView: some View {
        IPhoneLibraryView(
            items: items, playlists: playlists, player: player, libraryService: libraryService,
            isImporterPresented: $isImporterPresented,
            showsDeck: $isPhoneDeckPresented,
            aacResultMessage: $aacVersionResultMessage,
            showsAACResult: $aacVersionResultPresented,
            canCreateAACVersion: canCreateAACVersion,
            aacVersionExporter: aacVersionExporter,
            actions: IPhoneLibraryActions(
                createPlaylist: createPlaylist,
                renamePlaylist: renamePlaylist,
                deletePlaylist: deletePlaylist,
                addToPlaylist: addToPlaylist,
                createPlaylistWithItem: createPlaylist(with:),
                addItems: add,
                removeItem: remove,
                moveItems: move,
                createAACVersion: createAACVersion,
                exportItems: startExport,
                deleteItem: deleteLibraryItem
            )
        )
    }
    #endif

}

private extension MainView {
    static func makeAACVersionExporter() -> TransformedTrackExporter {
        #if DEBUG && os(iOS)
        PhoneLayoutUITestFixture.makeAACVersionExporter()
        #else
        TransformedTrackExporter()
        #endif
    }

    var aacResultPresentation: Binding<Bool> {
        #if os(iOS)
        Binding(
            get: { aacVersionResultPresented && !isPhoneDeckPresented },
            set: { if !$0 && !isPhoneDeckPresented { aacVersionResultPresented = false } }
        )
        #else
        $aacVersionResultPresented
        #endif
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

    func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let existingEntries = orderedEntries
        // UI offsets exclude entries left behind by deleted media items.
        var itemEntries = existingEntries.filter { $0.item != nil }
        guard source.isEmpty == false,
              source.allSatisfy({ itemEntries.indices.contains($0) }),
              (0...itemEntries.count).contains(destination) else { return }
        itemEntries.move(fromOffsets: source, toOffset: destination)
        let missingEntries = existingEntries.filter { $0.item == nil }
        for (index, entry) in (itemEntries + missingEntries).enumerated() {
            entry.sortIndex = index
        }
    }

    func moveItem(_ item: MediaItem, by offset: Int) {
        let items = orderedItems
        guard offset != 0, let sourceIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        let destinationIndex = sourceIndex + offset
        guard items.indices.contains(destinationIndex) else { return }
        moveItems(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destinationIndex + (offset > 0 ? 1 : 0)
        )
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

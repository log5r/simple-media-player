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

    var selection: SidebarSelection {
        get { browsingState.selection }
        nonmutating set { browsingState.select(newValue) }
    }
    var searchText: String {
        get { browsingState.searchText }
        nonmutating set { browsingState.searchText = newValue }
    }
    var searchFilter: LibrarySearchFilter {
        get { browsingState.searchFilter }
        nonmutating set { browsingState.searchFilter = newValue }
    }
    @State var importErrorPresented = false
    @State var addToPlaylistTarget: Playlist?
    var selectedItemID: UUID? {
        get { browsingState.selectedItemID }
        nonmutating set { browsingState.selectedItemID = newValue }
    }
    var librarySortField: LibrarySortField {
        get { browsingState.sortField }
        nonmutating set { browsingState.sortField = newValue }
    }
    var librarySortDirection: LibrarySortDirection {
        get { browsingState.sortDirection }
        nonmutating set { browsingState.sortDirection = newValue }
    }
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
    @State var sharedExportSession: SharedExportSession?
    @State var showsExportErrorsAfterSharing = false
    @State var isPhoneDeckPresented = false
    @State var showsPortraitLibrary = false
    @State var musicPickerMode: MusicLibraryPickerMode?
    @State var musicAccessProblem: MusicLibraryAccessProblem?
    @State var musicResultMessage: String?
    @Environment(\.openURL) var openURL
    @State private var keyboardIndependentSize = CGSize.zero
    #endif

    @State var browsingState = LibraryBrowsingState()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { proxy in
            let compact = usesCompactLayout(width: proxy.size.width)
            #if os(iOS)
            let hasDisplayDivision = DeckReservedRegions.hasDisplayDivision(in: proxy)
            let portraitPlayer = DuoPortraitPlayerLayout.isPreferred(
                size: keyboardIndependentSize == .zero ? proxy.size : keyboardIndependentSize, compact: compact,
                hasDisplayDivision: hasDisplayDivision
            )
            #else
            let portraitPlayer = false
            #endif
            withLibraryPresentations(libraryContent(compact: compact, size: proxy.size, portraitPlayer: portraitPlayer))
                .environment(\.usesPhoneLayout, compact)
                #if os(iOS)
                .environment(\.usesDividedDisplay, !compact && hasDisplayDivision)
                .onChange(of: portraitPlayer) { _, _ in showsPortraitLibrary = false }
                #endif
                #if DEBUG && os(iOS)
                .modifier(DuoLayoutDiagnostics(
                    layoutName: compact ? "compact" : "expanded", player: player, autoplayItems: items
                ))
                .modifier(DuoBrowsingDiagnostics(browsingState: browsingState))
                #endif
        }
        #if os(iOS)
        .background {
            // Measure posture independently; the foreground still avoids the keyboard.
            GeometryReader { _ in
                Color.clear
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { keyboardIndependentSize = $0 }
            }
            .ignoresSafeArea(.keyboard)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #endif
        .onChange(of: items.map(\.id)) { _, ids in
            browsingState.retainItems(ids: Set(ids))
        }
        .onChange(of: playlists.map(\.id)) { _, ids in
            browsingState.retainPlaylists(ids: Set(ids))
        }
        .onChange(of: browsingState.missingLibraryGroup(in: items), initial: true) { _, group in
            if let group { browsingState.removeLibraryGroup(group) }
        }
    }

    @ViewBuilder
    private func libraryContent(compact: Bool, size: CGSize, portraitPlayer: Bool) -> some View {
        #if os(iOS)
        if compact {
            phoneView
        } else {
            expandedIOSView(size: size, portraitPlayer: portraitPlayer)
                // A disappearing orientation branch must not cancel the new branch's shared projection.
                .modifier(libraryListUpdates)
        }
        #else
        desktopView(availableWidth: size.width)
            .modifier(libraryListUpdates)
        #endif
    }

    private func usesCompactLayout(width: CGFloat) -> Bool {
        #if os(iOS)
        #if DEBUG
        if let override = PhoneLayoutUITestFixture.layoutOverride { return override }
        #endif
        return LibraryLayoutPolicy.usesCompactLayout(horizontalSizeClass: horizontalSizeClass, width: width)
        #else
        return false
        #endif
    }

    func exportNamesView(_ plan: MediaExportPlan) -> some View {
        ExportMissingTitlesView(plan: plan) { names in
            namedExportRequest = (plan, names)
            closeExportNames()
        } cancel: {
            namedExportRequest = nil
            closeExportNames()
        }
    }

    func closeExportNames() {
        #if os(iOS)
        phoneExportSheet = nil
        #else
        pendingExportPlan = nil
        #endif
    }

    func finishExportSheet() {
        if let request = namedExportRequest {
            namedExportRequest = nil
            continueFinderExport(plan: request.plan, nameOverrides: request.names)
        } else {
            #if os(iOS)
            if sharedExportSession?.isCompleted == false { return }
            if showsExportErrorsAfterSharing {
                showsExportErrorsAfterSharing = false
                exportResultPresented = true
            }
            #endif
        }
    }

    var exportAlertTitle: String {
        #if os(iOS)
        L10n.string("Export")
        #else
        L10n.string("Export to Finder")
        #endif
    }

}

extension MainView {
    func desktopView(availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            libraryNavigation

            SeekBarView(player: player)
            BottomPanelView(
                player: player,
                selectedItem: selectedItem,
                queue: browsingPlaybackQueue,
                playItem: playBrowsingItem,
                requestSaveCopy: { item in
                    saveCopyTarget = item
                },
                availableWidth: availableWidth
            )
        }
    }

    var libraryListUpdates: LibraryListUpdates {
        LibraryListUpdates(
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
        )
    }

    var libraryNavigation: some View {
            NavigationSplitView {
                SidebarView(
                    selection: Binding(get: { selection }, set: { browsingState.select($0) }),
                    playlists: playlists,
                    createPlaylist: { _ = createPlaylist() },
                    renamePlaylist: renamePlaylist,
                    deletePlaylist: deletePlaylist,
                    browsingState: browsingState
                )
                #if os(iOS)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
                #endif
            } detail: {
                libraryDetail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .minFrame()

    }

    var libraryDetail: some View {
                DetailAreaView(
                    browsingState: browsingState,
                    items: filteredItems,
                    allQueue: browsingPlaybackQueue,
                    selectedSection: selectedSection,
                    activePlaylist: selectedPlaylist,
                    title: navigationTitle,
                    searchText: $browsingState.searchText,
                    searchFilter: $browsingState.searchFilter,
                    librarySortField: $browsingState.sortField,
                    librarySortDirection: $browsingState.sortDirection,
                    showLyricsPanel: $showLyricsPanel,
                    isImporterPresented: $isImporterPresented,
                    selectedItemID: $browsingState.selectedItemID,
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
                    },
                    playItem: playBrowsingItem,
                    musicLibraryActions: musicLibraryActions
                )
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
                deleteItem: deleteLibraryItem,
                showAddTracks: { addToPlaylistTarget = $0 },
                requestSaveCopy: { saveCopyTarget = $0 },
                musicLibrary: musicLibraryActions
            ),
            browsingState: browsingState
        )
    }
    #endif

    var musicLibraryActions: MusicLibraryActions {
        #if os(iOS)
        MusicLibraryActions(
            play: { requestMusicLibraryPicker(.play) },
            importSongs: { requestMusicLibraryPicker(.importing) }
        )
        #else
        MusicLibraryActions()
        #endif
    }

}

extension MainView {
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

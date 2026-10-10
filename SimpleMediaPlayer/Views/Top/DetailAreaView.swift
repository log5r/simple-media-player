import SwiftUI

struct DetailAreaView: View {
    @Bindable var browsingState: LibraryBrowsingState
    let items: [MediaItem]
    let allQueue: [MediaItem]
    let selectedSection: LibrarySection?
    let activePlaylist: Playlist?
    let title: String
    @Binding var searchText: String
    @Binding var searchFilter: LibrarySearchFilter
    @Binding var librarySortField: LibrarySortField
    @Binding var librarySortDirection: LibrarySortDirection
    @Binding var showLyricsPanel: Bool
    @Binding var isImporterPresented: Bool
    @Binding var selectedItemID: UUID?
    let libraryService: LibraryService
    let player: PlayerViewModel
    let playlists: [Playlist]
    let addToPlaylist: (MediaItem, Playlist) -> Void
    let createPlaylistWithItem: (MediaItem) -> Void
    let removeFromPlaylist: (MediaItem) -> Void
    let movePlaylistItem: (MediaItem, Int) -> Void
    let createAACVersion: (MediaItem) -> Void
    let canCreateAACVersion: Bool
    let aacVersionExporter: TransformedTrackExporter
    let aacVersionSourceTitle: String?
    let createPlaylist: () -> Void
    let showAddToPlaylistSheet: () -> Void
    let exportToFinder: () -> Void
    let requestSaveCopy: (MediaItem) -> Void
    let deleteItem: (MediaItem) -> Void
    let playItem: (MediaItem) -> Void
    var musicLibraryActions = MusicLibraryActions()

    var isSettingsPresented: Bool {
        get { browsingState.showsSettings }
        nonmutating set { browsingState.showsSettings = newValue }
    }
    var isAdvancedSearchPresented: Bool {
        get { browsingState.showsFilters }
        nonmutating set { browsingState.showsFilters = newValue }
    }
    var isBulkEditMode: Bool {
        get { browsingState.isBulkEditMode }
        nonmutating set { browsingState.isBulkEditMode = newValue }
    }
    var bulkSelection: BulkMediaSelectionState { browsingState.bulkSelection }
    @State var availableSize = CGSize.zero
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    var bulkEditSession: BulkMetadataEditSession? {
        get { browsingState.bulkEditSession }
        nonmutating set { browsingState.bulkEditSession = newValue }
    }
    @State var rapidSelectionDurationMilliseconds = "pending"
    @AppStorage(AppSettingsKey.showEqualizerPanel)
    var showEqualizerPanel = AppSettingsDefault.showEqualizerPanel
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if player.showVideoArea, player.currentItem?.isVideo == true {
                    VideoAreaView(player: player, presentVideoFullScreen: {
                        browsingState.showsVideoFullScreen = true
                    })
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if shouldShowEqualizerPanel {
                                EqualizerPanelView(player: player)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                } else {
                    MediaListView(
                        items: items,
                        queue: allQueue,
                        section: selectedSection,
                        activePlaylist: activePlaylist,
                        playlists: playlists,
                        libraryService: libraryService,
                        player: player,
                        librarySortField: $librarySortField,
                        librarySortDirection: $librarySortDirection,
                        addToPlaylist: addToPlaylist,
                        createPlaylistWithItem: createPlaylistWithItem,
                        removeFromPlaylist: removeFromPlaylist,
                        movePlaylistItem: movePlaylistItem,
                        createAACVersion: createAACVersion,
                        canCreateAACVersion: canCreateAACVersion,
                        deleteItem: deleteItem,
                        selectedItemID: $selectedItemID,
                        isBulkEditMode: $browsingState.isBulkEditMode,
                        bulkSelection: bulkSelection,
                        browsingState: browsingState
                    )
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            if isBulkEditMode {
                                bulkSelectionPrompt
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }

                            if shouldShowVideoResumePrompt {
                                videoResumePrompt
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }

                            if shouldShowEqualizerPanel {
                                EqualizerPanelView(player: player)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                }
            }

            if shouldShowLyricsPanel {
                LyricsPanelView(
                    item: player.currentItem,
                    listIndex: currentItemListIndex,
                    libraryService: libraryService,
                    browsingState: inlineLyricsBrowsingState
                )
                    .frame(minWidth: detailPanelMinimumWidth, idealWidth: detailPanelWidth,
                           maxWidth: detailPanelMaximumWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { availableSize = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showLyricsPanel)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showEqualizerPanel)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: player.currentItem?.isVideo)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isBulkEditMode)
        .focusedSceneValue(\.appMenuActions, appMenuActions)
        .overlay(alignment: .top) {
            if libraryService.isImporting {
                ObservedProgressView(source: libraryService, value: \.importProgress)
                    .progressViewStyle(.linear)
            } else if libraryService.isExporting {
                ObservedProgressView(source: libraryService, value: \.exportProgress)
                    .progressViewStyle(.linear)
            } else if aacVersionExporter.isExporting {
                ObservedProgressView(source: aacVersionExporter, value: \.progress)
                    .progressViewStyle(.linear)
            } else if let preparation = libraryService.exportPlanPreparation {
                ObservedProgressView(source: preparation, value: \.fractionCompleted)
                    .progressViewStyle(.linear)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 12) {
                // Preparing an export does not block importing, so its panel can sit above the import panel.
                if let preparation = libraryService.exportPlanPreparation {
                    ExportPlanPreparationPanel(
                        preparation: preparation, cancel: libraryService.cancelExportPlanPreparation
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let preparation = libraryService.musicLibraryPreparation {
                    MusicLibraryPreparationPanel(
                        preparation: preparation, cancel: libraryService.cancelMusicLibraryPreparation
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if libraryService.isImporting {
                    ImportProgressPanel(libraryService: libraryService)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if libraryService.isExporting {
                    ExportProgressPanel(libraryService: libraryService)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if aacVersionExporter.isExporting {
                    AACVersionProgressPanel(
                        exporter: aacVersionExporter,
                        sourceTitle: aacVersionSourceTitle
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(16)
        }
        .navigationTitle(title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar { detailToolbar }
        #if os(macOS)
        .sheet(isPresented: $browsingState.showsSettings) {
            AppSettingsView(player: player)
        }
        .sheet(item: $browsingState.bulkEditSession, onDismiss: {
            bulkSelection.reset()
        }, content: { session in
            BulkMetadataEditView(items: session.items, libraryService: libraryService)
        })
        #endif
    }

}

import SwiftUI

struct DetailAreaView: View {
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

    @State private var isSettingsPresented = false
    @State private var isAdvancedSearchPresented = false
    @State private var isBulkEditMode = false
    @State private var bulkSelection = BulkMediaSelectionState()
    @State private var bulkEditSession: BulkMetadataEditSession?
    @State private var rapidSelectionDurationMilliseconds = "pending"
    @AppStorage(AppSettingsKey.showEqualizerPanel)
    private var showEqualizerPanel = AppSettingsDefault.showEqualizerPanel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if player.showVideoArea, player.currentItem?.isVideo == true {
                    VideoAreaView(player: player)
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
                        isBulkEditMode: $isBulkEditMode,
                        bulkSelection: bulkSelection
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
                    libraryService: libraryService
                )
                    .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showLyricsPanel)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showEqualizerPanel)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: player.currentItem?.isVideo)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isBulkEditMode)
        .focusedSceneValue(\.appMenuActions, appMenuActions)
        .overlay(alignment: .top) {
            if libraryService.isImporting {
                ProgressView(value: libraryService.importProgress)
                    .progressViewStyle(.linear)
            } else if libraryService.isExporting {
                ProgressView(value: libraryService.exportProgress)
                    .progressViewStyle(.linear)
            } else if aacVersionExporter.isExporting {
                ProgressView(value: aacVersionExporter.progress)
                    .progressViewStyle(.linear)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if libraryService.isImporting {
                ImportProgressPanel(libraryService: libraryService)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if libraryService.isExporting {
                ExportProgressPanel(libraryService: libraryService)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if aacVersionExporter.isExporting {
                AACVersionProgressPanel(
                    progress: aacVersionExporter.progress,
                    sourceTitle: aacVersionSourceTitle
                )
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            // Group 1: Library actions — add tracks, import, export, and editing.
            ToolbarItemGroup {
                if activePlaylist != nil {
                    Button {
                        showAddToPlaylistSheet()
                    } label: {
                        Label("Add Tracks", systemImage: "plus")
                    }
                    .disabled(isBulkEditMode)
                    .help("Add tracks to the playlist")
                }

                Button {
                    isImporterPresented = true
                } label: {
                    Label("Import...", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("importMediaButton")
                .disabled(isBulkEditMode || libraryService.isImporting || aacVersionExporter.isExporting)
                .help("Import media files")

                #if os(macOS)
                Button {
                    exportToFinder()
                } label: {
                    Label("Export to Finder", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("exportToFinderButton")
                .disabled(
                    isBulkEditMode || items.isEmpty || libraryService.isImporting
                        || libraryService.isExporting || aacVersionExporter.isExporting
                )
                .help("Export to Finder")
                #endif
                if isMediaListVisible, isBulkEditMode {
                    Button(role: .destructive) {
                        cancelBulkEditMode()
                    } label: {
                        Label("Cancel Multiple Edit", systemImage: "xmark")
                            .foregroundStyle(.red)
                    }
                    .accessibilityIdentifier("cancelMultipleEditButton")
                    .help("Cancel multiple edit")

                    Button {
                        bulkEditSession = BulkMetadataEditSession(items: selectedBulkItems)
                        isBulkEditMode = false
                    } label: {
                        PanelToolbarLabel(
                            title: "Edit Selected",
                            systemImage: "pencil",
                            isSelected: true
                        )
                    }
                    .accessibilityIdentifier("editSelectedMediaButton")
                    .accessibilityValue("\(selectedBulkItems.count)")
                    .disabled(
                        selectedBulkItems.isEmpty || libraryService.isImporting
                            || libraryService.isExporting || aacVersionExporter.isExporting
                    )
                    .help("Edit selected media")
                } else if isMediaListVisible {
                    Button {
                        isBulkEditMode = true
                        bulkSelection.reset()
                    } label: {
                        Label("Multiple Edit", systemImage: "checklist")
                    }
                    .accessibilityIdentifier("multipleEditButton")
                    .disabled(
                        items.isEmpty || libraryService.isImporting
                            || libraryService.isExporting || aacVersionExporter.isExporting
                    )
                    .help("Select multiple media to edit metadata")
                }
            }

            ToolbarSpacer(.fixed)

            // Group 2: View toggles.
            ToolbarItemGroup {
                if player.currentItem?.isVideo == true, player.showVideoArea == false {
                    Button {
                        player.showVideoArea = true
                    } label: {
                        Label("Show Video", systemImage: "play.rectangle")
                    }
                    .disabled(isBulkEditMode)
                    .help("Show the playing video")
                }

                if player.currentItem?.isVideo != true {
                    Button {
                        showLyricsPanel.toggle()
                    } label: {
                        PanelToolbarLabel(
                            title: "Details",
                            systemImage: "sidebar.trailing",
                            isSelected: shouldShowLyricsPanel
                        )
                    }
                    .accessibilityIdentifier("lyricsButton")
                    .accessibilityValue(L10n.string(shouldShowLyricsPanel ? "Visible" : "Hidden"))
                    .disabled(isBulkEditMode)
                    .help("Details")
                }

                Button {
                    showEqualizerPanel.toggle()
                } label: {
                    PanelToolbarLabel(
                        title: "Equalizer",
                        systemImage: "slider.vertical.3",
                        isSelected: shouldShowEqualizerPanel
                    )
                }
                .accessibilityIdentifier("equalizerButton")
                .accessibilityValue(L10n.string(shouldShowEqualizerPanel ? "Visible" : "Hidden"))
                .disabled(isBulkEditMode)
                .help("Equalizer")
            }

            ToolbarSpacer(.fixed)

            // Group 3: App-level settings.
            ToolbarItemGroup {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settingsButton")
                .accessibilityValue(L10n.string(isSettingsPresented ? "Visible" : "Hidden"))
                .disabled(isBulkEditMode)
                .help("Settings")
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAdvancedSearchPresented = true
                } label: {
                    Label(
                        "Filters",
                        systemImage: searchFilter.isActive
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
                .foregroundStyle(searchFilter.isActive ? Color.accentColor : Color.primary)
                .accessibilityIdentifier("advancedSearchButton")
                .accessibilityValue(L10n.string(isAdvancedSearchPresented ? "Visible" : "Hidden"))
                .help("Show advanced search filters")
                .popover(isPresented: $isAdvancedSearchPresented) {
                    AdvancedSearchView(filter: $searchFilter)
                }
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            AppSettingsView(player: player)
        }
        .sheet(item: $bulkEditSession, onDismiss: {
            bulkSelection.reset()
        }, content: { session in
            BulkMetadataEditView(items: session.items, libraryService: libraryService)
        })
        .onChange(of: items.map(\.id)) { _, ids in
            bulkSelection.retain(ids: Set(ids))
            if selectedBulkItems.isEmpty, isBulkEditMode, ids.isEmpty {
                isBulkEditMode = false
            }
        }
    }

    private var shouldShowLyricsPanel: Bool {
        showLyricsPanel && player.currentItem?.isVideo != true
    }

    private var currentItemListIndex: Int? {
        guard let currentItemID = player.currentItem?.id,
              let index = items.firstIndex(where: { $0.id == currentItemID })
        else { return nil }
        return index + 1
    }

    private var shouldShowEqualizerPanel: Bool {
        showEqualizerPanel
    }

    private var isMediaListVisible: Bool {
        (player.showVideoArea && player.currentItem?.isVideo == true) == false
    }

    private var selectedBulkItems: [MediaItem] {
        items.filter { bulkSelection.contains($0.id) }
    }

    private var selectedItem: MediaItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    private var adjustmentTargetItem: MediaItem? {
        player.currentItem ?? selectedItem
    }

    private var appMenuActions: AppMenuActions {
        let isBusy = libraryService.isImporting || libraryService.isExporting || aacVersionExporter.isExporting
        let canShowMediaList = player.currentItem?.isVideo == true
        let canPlay = player.currentItem != nil || selectedItem != nil

        return AppMenuActions(
            showSettings: AppMenuAction {
                isSettingsPresented = true
            },
            exportToFinder: AppMenuAction(isEnabled: items.isEmpty == false && isBusy == false) {
                exportToFinder()
            },
            saveAdjustedCopy: AppMenuAction(
                isEnabled: adjustmentTargetItem?.isVideo == false
                    && player.isVideoMode == false
                    && player.hasPitchOrRateAdjustment
            ) {
                if let adjustmentTargetItem {
                    requestSaveCopy(adjustmentTargetItem)
                }
            },
            createPlaylist: AppMenuAction {
                createPlaylist()
            },
            addTracksToPlaylist: AppMenuAction(isEnabled: activePlaylist != nil && isBusy == false) {
                showAddToPlaylistSheet()
            },
            beginMultipleEdit: AppMenuAction(
                isEnabled: isMediaListVisible && isBulkEditMode == false && items.isEmpty == false && isBusy == false
            ) {
                isBulkEditMode = true
                bulkSelection.reset()
            },
            editSelectedMedia: AppMenuAction(
                isEnabled: isBulkEditMode && selectedBulkItems.isEmpty == false && isBusy == false
            ) {
                bulkEditSession = BulkMetadataEditSession(items: selectedBulkItems)
                isBulkEditMode = false
            },
            cancelMultipleEdit: AppMenuAction(isEnabled: isBulkEditMode) {
                cancelBulkEditMode()
            },
            toggleLyrics: AppMenuAction(isEnabled: player.currentItem?.isVideo != true) {
                showLyricsPanel.toggle()
            },
            toggleEqualizer: AppMenuAction(isEnabled: isBulkEditMode == false) {
                showEqualizerPanel.toggle()
            },
            toggleVideoArea: AppMenuAction(isEnabled: canShowMediaList) {
                player.showVideoArea.toggle()
            },
            playPause: AppMenuAction(isEnabled: canPlay) {
                playOrPauseSelectedItem()
            },
            previousTrack: AppMenuAction(isEnabled: canSkipToPrevious) {
                skipToPrevious()
            },
            nextTrack: AppMenuAction(isEnabled: canSkipToNext) {
                skipToNext()
            },
            lyricsAreVisible: shouldShowLyricsPanel,
            equalizerIsVisible: shouldShowEqualizerPanel,
            videoAreaIsVisible: player.showVideoArea && player.currentItem?.isVideo == true
        )
    }

    private var canSkipToPrevious: Bool {
        if player.currentItem != nil {
            return player.canSkipToPrevious || player.currentTime >= 3
        }
        return adjacentSelectedItem(offset: -1) != nil
    }

    private var canSkipToNext: Bool {
        if player.currentItem != nil {
            return player.canSkipToNext
        }
        return adjacentSelectedItem(offset: 1) != nil
    }

    private func playOrPauseSelectedItem() {
        if player.canPause {
            player.pause()
        } else if let selectedItem, player.currentItem?.id != selectedItem.id {
            player.play(item: selectedItem, in: allQueue)
        } else {
            player.resume()
        }
    }

    private func skipToPrevious() {
        if player.currentItem != nil {
            player.previous()
        } else if let item = adjacentSelectedItem(offset: -1) {
            player.play(item: item, in: allQueue)
        }
    }

    private func skipToNext() {
        if player.currentItem != nil {
            player.next()
        } else if let item = adjacentSelectedItem(offset: 1) {
            player.play(item: item, in: allQueue)
        }
    }

    private func adjacentSelectedItem(offset: Int) -> MediaItem? {
        guard let selectedItem, let index = allQueue.firstIndex(where: { $0.id == selectedItem.id }) else {
            return nil
        }
        let targetIndex = index + offset
        guard allQueue.indices.contains(targetIndex) else { return nil }
        return allQueue[targetIndex]
    }

    private func cancelBulkEditMode() {
        isBulkEditMode = false
        bulkSelection.reset()
    }

    private var shouldShowVideoResumePrompt: Bool {
        player.currentItem?.isVideo == true && player.showVideoArea == false
    }

    private var videoResumePrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentItem?.title ?? L10n.string("Playing Video"))
                    .font(.headline)
                    .lineLimit(1)
                Text(player.isPlaying ? L10n.string("Video is playing") : L10n.string("Video is paused"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                player.showVideoArea = true
            } label: {
                Label("Show Video", systemImage: "play.rectangle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var bulkSelectionPrompt: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(.tint)

                Text(L10n.string("Multiple media selection mode: Click to select or deselect. Drag to select a range."))
                    .font(.callout.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("bulkSelectionStatus")
            .accessibilityValue("\(bulkSelection.ids.count)")

            Spacer(minLength: 12)

            #if os(macOS)
            if RapidBulkSelectionUITestDriver.isEnabled {
                HStack(spacing: 8) {
                    Text("Rapid selection duration")
                        .monospacedDigit()
                        .accessibilityIdentifier("rapidSelectionDuration")
                        .accessibilityValue(rapidSelectionDurationMilliseconds)

                    Button("Run 4 clicks/sec test") {
                        rapidSelectionDurationMilliseconds = "pending"
                        RapidBulkSelectionUITestDriver.selectRows(
                            selection: bulkSelection,
                            rowIDs: items.map(\.id)
                        ) { elapsed in
                            rapidSelectionDurationMilliseconds = "\(Int((elapsed * 1_000).rounded()))"
                        }
                    }
                    .accessibilityIdentifier("rapidSelectionTestButton")
                }
            }
            #endif

            Button("Cancel") {
                cancelBulkEditMode()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("bulkSelectionCancelButton")
            .help("Cancel multiple edit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct PanelToolbarLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .foregroundStyle(labelColor)
    }

    private var labelColor: Color {
        guard isEnabled else { return .secondary }
        return isSelected ? .accentColor : .primary
    }
}

private struct AACVersionProgressPanel: View {
    let progress: Double
    let sourceTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Creating AAC Version")
                    .font(.headline)
            }

            ProgressView(value: clampedProgress)
                .progressViewStyle(.linear)

            if let sourceTitle {
                Text(sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .shadow(radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Creating AAC version")
        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}

private struct BulkMetadataEditSession: Identifiable {
    let id = UUID()
    let items: [MediaItem]
}

private struct ImportProgressPanel: View {
    let libraryService: LibraryService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Importing")
                    .font(.headline)
                Spacer(minLength: 16)
                Text(progressCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: clampedProgress)
                .progressViewStyle(.linear)

            if let fileName = libraryService.currentImportFileName {
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .shadow(radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing media")
        .accessibilityValue("\(libraryService.importCompletedFileCount) / \(libraryService.importTotalFileCount)")
    }

    private var clampedProgress: Double {
        min(max(libraryService.importProgress, 0), 1)
    }

    private var progressCountText: String {
        "\(libraryService.importCompletedFileCount)/\(libraryService.importTotalFileCount)"
    }
}

private struct ExportProgressPanel: View {
    let libraryService: LibraryService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Exporting")
                    .font(.headline)
                Spacer(minLength: 16)
                Text(progressCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: clampedProgress)
                .progressViewStyle(.linear)

            if let fileName = libraryService.currentExportFileName {
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .shadow(radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exporting media")
        .accessibilityValue("\(libraryService.exportCompletedFileCount) / \(libraryService.exportTotalFileCount)")
    }

    private var clampedProgress: Double {
        min(max(libraryService.exportProgress, 0), 1)
    }

    private var progressCountText: String {
        "\(libraryService.exportCompletedFileCount)/\(libraryService.exportTotalFileCount)"
    }
}

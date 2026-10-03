import SwiftUI

extension DetailAreaView {
    @ToolbarContentBuilder
    var detailToolbar: some ToolbarContent {
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

                Button {
                    exportToFinder()
                } label: {
                    #if os(macOS)
                    Label("Export to Finder", systemImage: "square.and.arrow.up")
                    #else
                    Label("Export…", systemImage: "square.and.arrow.up")
                    #endif
                }
                .accessibilityIdentifier("exportToFinderButton")
                .disabled(
                    isBulkEditMode || items.isEmpty || libraryService.isImporting
                        || libraryService.isExporting || aacVersionExporter.isExporting
                )
                .help("Export")
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
                        toggleDetails()
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
                    toggleEqualizer()
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
            .prefersVerticalToolbarPlacement()

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
            .prefersVerticalToolbarPlacement()

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
                #if os(macOS)
                .popover(isPresented: $browsingState.showsFilters) {
                    AdvancedSearchView(filter: $searchFilter)
                }
                #endif
            }
            .prefersVerticalToolbarPlacement()
    }
}

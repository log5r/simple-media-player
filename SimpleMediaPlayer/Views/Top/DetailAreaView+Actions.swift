import SwiftUI

extension DetailAreaView {
    var inlineLyricsBrowsingState: LibraryBrowsingState? {
        #if os(iOS)
        browsingState
        #else
        nil
        #endif
    }

    var shouldShowLyricsPanel: Bool {
        showLyricsPanel && player.currentItem?.isVideo != true && permitsInlineDetails
    }

    var currentItemListIndex: Int? {
        guard let currentItemID = player.currentItem?.id,
              let index = allQueue.firstIndex(where: { $0.id == currentItemID })
        else { return nil }
        return index + 1
    }

    var shouldShowEqualizerPanel: Bool {
        showEqualizerPanel && permitsInlineEqualizer
    }

    var isMediaListVisible: Bool {
        (player.showVideoArea && player.currentItem?.isVideo == true) == false
    }

    var selectedBulkItems: [MediaItem] {
        items.filter { bulkSelection.contains($0.id) }
    }

    var selectedItem: MediaItem? {
        guard let selectedItemID else { return nil }
        return allQueue.first { $0.id == selectedItemID }
    }

    var adjustmentTargetItem: MediaItem? {
        player.currentItem ?? selectedItem
    }

    var appMenuActions: AppMenuActions {
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

    var canSkipToPrevious: Bool {
        if player.currentItem != nil {
            return player.canSkipToPrevious || player.currentTime >= 3
        }
        return adjacentSelectedItem(offset: -1) != nil
    }

    var canSkipToNext: Bool {
        if player.currentItem != nil {
            return player.canSkipToNext
        }
        return adjacentSelectedItem(offset: 1) != nil
    }

    func playOrPauseSelectedItem() {
        if player.canPause {
            player.pause()
        } else if let selectedItem, player.currentItem?.id != selectedItem.id {
            playItem(selectedItem)
        } else {
            player.resume()
        }
    }

    func skipToPrevious() {
        if player.currentItem != nil {
            player.previous()
        } else if let item = adjacentSelectedItem(offset: -1) {
            playItem(item)
        }
    }

    func skipToNext() {
        if player.currentItem != nil {
            player.next()
        } else if let item = adjacentSelectedItem(offset: 1) {
            playItem(item)
        }
    }

    func adjacentSelectedItem(offset: Int) -> MediaItem? {
        guard let selectedItem, let index = allQueue.firstIndex(where: { $0.id == selectedItem.id }) else {
            return nil
        }
        let targetIndex = index + offset
        guard allQueue.indices.contains(targetIndex) else { return nil }
        return allQueue[targetIndex]
    }

    func cancelBulkEditMode() {
        isBulkEditMode = false
        bulkSelection.reset()
    }

    var shouldShowVideoResumePrompt: Bool {
        player.currentItem?.isVideo == true && player.showVideoArea == false
    }

    var videoResumePrompt: some View {
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

    var bulkSelectionPrompt: some View {
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

extension DetailAreaView {
    var permitsInlineDetails: Bool {
        #if os(iOS)
        LibraryLayoutPolicy.showsInlineDetails(
            size: availableSize, accessibilityText: dynamicTypeSize.isAccessibilitySize
        )
        #else
        true
        #endif
    }

    var permitsInlineEqualizer: Bool {
        #if os(iOS)
        LibraryLayoutPolicy.showsInlineEqualizer(
            size: availableSize, accessibilityText: dynamicTypeSize.isAccessibilitySize
        )
        #else
        true
        #endif
    }

    var detailPanelMinimumWidth: CGFloat {
        #if os(iOS)
        240
        #else
        280
        #endif
    }

    var detailPanelMaximumWidth: CGFloat {
        #if os(iOS)
        240
        #else
        320
        #endif
    }

    var detailPanelWidth: CGFloat {
        #if os(iOS)
        240
        #else
        300
        #endif
    }

    func toggleDetails() {
        #if os(iOS)
        if !permitsInlineDetails { browsingState.showsDetails = true; return }
        #endif
        showLyricsPanel.toggle()
    }

    func toggleEqualizer() {
        #if os(iOS)
        if !permitsInlineEqualizer { browsingState.showsEqualizer = true; return }
        #endif
        showEqualizerPanel.toggle()
    }
}

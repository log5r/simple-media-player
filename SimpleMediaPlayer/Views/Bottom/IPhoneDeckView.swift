#if os(iOS)
import AVKit
import SwiftData
import SwiftUI

private enum IPhoneDeckPage: String, CaseIterable {
    case display = "Display"
    case lyrics = "Lyrics"
    case info = "Info"
    case upNext = "Up Next"
}

struct IPhoneDeckView: View {
    let player: PlayerViewModel
    let libraryService: LibraryService
    let listName: String
    let canCreateAACVersion: Bool
    let createAACVersion: (MediaItem) -> Void
    @Binding var isPresented: Bool
    @Binding var aacResultMessage: String
    @Binding var showsAACResult: Bool
    var showExpandedLibrary: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var page = IPhoneDeckPage.display
    @State private var showsAdjustments = false
    @State private var infoItem: MediaItem?
    @State private var lyricsItem: MediaItem?
    @State private var saveItem: MediaItem?
    @State private var pendingSaveItem: MediaItem?
    @State private var showsVideoFullScreen = false
    @State private var showsSettings = false
    @State private var showsEqualizer = false
    @State private var informationRevision = 0

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    if page == .display {
                        if usesExpandedDisplay(in: proxy) {
                            expandedDisplay(size: proxy.size).padding(.bottom, 12)
                        } else {
                            IPhoneDeckArrangementView { height, compactDisplay in
                                display(height: height, compactDisplay: compactDisplay)
                            } controls: {
                                displayControls
                            }
                        }
                    } else {
                        pageLayout
                    }
                    DeckSafeRow(
                        height: (dynamicTypeSize.isAccessibilitySize ? 64 : IPhoneDeckLayout.rowHeight)
                            + IPhoneDeckLayout.bottomPadding
                    ) { pageSwitcher }
                }
            }
            .background(palette.panelBackground.ignoresSafeArea())
            .navigationTitle(listName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { deckToolbar }
        }
        .accessibilityIdentifier("phoneDeck")
        .sheet(isPresented: $showsAdjustments, onDismiss: {
            saveItem = pendingSaveItem
            pendingSaveItem = nil
        }, content: {
            IPhoneAdjustmentView(player: player) {
                pendingSaveItem = libraryCurrentItem
                showsAdjustments = false
            }
            .presentationDetents([.medium, .large])
        })
        .sheet(item: $infoItem, onDismiss: { informationRevision += 1 }, content: { item in
            MediaInfoView(item: item, libraryService: libraryService)
        })
        .sheet(item: $lyricsItem) { item in LyricsEditorView(item: item, libraryService: libraryService) }
        .sheet(isPresented: $showsSettings) { AppSettingsView(player: player) }
        .sheet(isPresented: $showsEqualizer) {
            NavigationStack {
                ScrollView { EqualizerPanelView(player: player) }
                    .navigationTitle("Equalizer")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { showsEqualizer = false }
                        }
                    }
                    .disablesVerticalToolbar()
            }
        }
        .sheet(item: $saveItem) { item in
            SaveTransformedCopyView(
                item: item, player: player, libraryService: libraryService, modelContext: modelContext,
                onComplete: { _ in saveItem = nil }, onCancel: { saveItem = nil }
            )
        }
        .fullScreenCover(isPresented: $showsVideoFullScreen) { FullScreenVideoView(player: player) }
        .alert("Create AAC Version", isPresented: Binding(
            get: { showsAACResult && isPresented },
            set: { if !$0 && isPresented { showsAACResult = false } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(aacResultMessage) }
        .onChange(of: player.currentItem?.id) { _, id in
            if id == nil { isPresented = false }
        }
        .onChange(of: player.isVideoMode) { _, isVideo in
            if !isVideo { showsVideoFullScreen = false }
        }
    }

    private func usesExpandedDisplay(in proxy: GeometryProxy) -> Bool {
        #if DEBUG
        if PhoneLayoutUITestFixture.layoutOverride == true { return false }
        #endif
        return horizontalSizeClass == .regular && DeckReservedRegions.hasDisplayDivision(in: proxy)
    }

    @ViewBuilder private func expandedDisplay(size: CGSize) -> some View {
        if size.height > size.width {
            DuoPortraitPlayerView(
                player: player, selectedItem: player.currentItem, queue: player.queue,
                playItem: { player.play(item: $0, in: player.queue) }, requestSaveCopy: requestSaveCopy,
                showLibrary: showExpandedLibrary, showSettings: { showsSettings = true },
                showEqualizer: { showsEqualizer = true }, showDetails: { page = .info },
                showVideoFullScreen: { showsVideoFullScreen = true }
            )
        } else {
            DuoLandscapePlayerView(
                player: player, selectedItem: player.currentItem, queue: player.queue,
                playItem: { player.play(item: $0, in: player.queue) }, requestSaveCopy: requestSaveCopy,
                showLibrary: showExpandedLibrary, showSettings: { showsSettings = true },
                showEqualizer: { showsEqualizer = true }, showDetails: { page = .info },
                showVideoFullScreen: { showsVideoFullScreen = true }
            )
        }
    }

    /// Songs played from Music without saving have no library item to edit, copy, or convert.
    private var libraryCurrentItem: MediaItem? {
        guard let item = player.currentItem, item.isInLibrary else { return nil }
        return item
    }

    private func requestSaveCopy(_ item: MediaItem) {
        guard item.isInLibrary else { return }
        saveItem = item
    }

    @ToolbarContentBuilder private var deckToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "chevron.down") { isPresented = false }
                .accessibilityIdentifier("phoneDeckClose")
        }
        .visibilityPriority(.high)
        if page == .lyrics {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit Lyrics…", systemImage: "square.and.pencil") { lyricsItem = libraryCurrentItem }
                    .disabled(libraryCurrentItem == nil || player.isVideoMode)
            }
            .visibilityPriority(.high)
        } else {
            moreMenu
        }
    }

    @ViewBuilder private func display(height: CGFloat, compactDisplay: Bool) -> some View {
        let plateCorner = IPhoneDeckLayout.displayCornerRadius
        let bezel = IPhoneDeckLayout.displayBezelHeight / 2
        if player.isVideoMode {
            VideoAreaView(player: player, showsBackToListButton: false,
                          presentVideoFullScreen: { showsVideoFullScreen = true })
                .frame(height: height).clipShape(RoundedRectangle(cornerRadius: plateCorner))
        } else {
            LEDDisplayView(
                player: player, height: height,
                visualizerHeight: IPhoneDeckLayout.visualizerHeight(
                    displayHeight: height, compactControls: compactDisplay
                ),
                layout: height < 200 ? .phoneStrip : .phoneDeck
            )
                // The plate keeps its size, so its LED fonts stop growing at the largest standard text size.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .clipShape(RoundedRectangle(cornerRadius: plateCorner - bezel))
                .padding(bezel).background(palette.displayBezelFill, in: RoundedRectangle(cornerRadius: plateCorner))
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .lyrics, .info:
            LyricsPanelView(
                item: player.currentItem,
                listIndex: player.queue.firstIndex(where: { $0.id == player.currentItem?.id }).map { $0 + 1 },
                libraryService: libraryService, page: page == .lyrics ? .lyrics : .information,
                playbackPlayer: player, showsEditBar: false, informationRevision: informationRevision
            )
        case .upNext:
            List(player.queue) { item in
                Button { player.play(item: item, in: player.queue) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title).lineLimit(1)
                            Text(item.displayArtist).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.id == player.currentItem?.id { Image(systemName: "speaker.wave.2.fill") }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("phoneQueue.\(item.id)")
                    .accessibilityValue(item.id == player.currentItem?.id ? queuePlaybackState : "")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        case .display: EmptyView()
        }
    }

    private var indicators: some View {
        IPhoneDeckCellRow(spacing: IPhoneDeckLayout.rowSpacing) {
            lamp("EQ", label: "Equalizer", value: player.activeEqualizerPresetName, active: player.equalizer.isEnabled)
            lamp(
                "KEY", label: "Key",
                value: PitchSpeedTextFormatter.pitch(pitchSpeedAvailable ? player.pitchSemitones : 0),
                active: pitchSpeedAvailable && player.pitchSemitones != 0
            ).disabled(!pitchSpeedAvailable)
            lamp(
                "SPEED", label: "Speed",
                value: PitchSpeedTextFormatter.rate(pitchSpeedAvailable ? player.playbackRate : 1),
                active: pitchSpeedAvailable && abs(player.playbackRate - 1) > 0.001
            ).disabled(!pitchSpeedAvailable)
        }
    }

    private func lamp(_ title: String, label: String, value: String, active: Bool) -> some View {
        Button { showsAdjustments = true } label: {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(active ? palette.indicatorLEDOn : palette.indicatorLEDOff)
                        .frame(width: 7, height: 7).shadow(color: active ? palette.indicatorLEDGlow : .clear, radius: 4)
                    // The untranslated legend stays on one line at accessibility sizes.
                    Text(title).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.5)
                }
                Text(value).font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
            }
            .foregroundStyle(palette.labelColor)
            .frame(maxWidth: .infinity, minHeight: IPhoneDeckLayout.rowHeight)
            .background(palette.normalButtonFill)
            .iPhoneDeckControlFrame(palette)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(String.LocalizationValue(label))).accessibilityValue(value)
        .accessibilityHint("Open playback adjustments")
        .accessibilityIdentifier("phoneLamp.\(title)")
    }
}

private extension IPhoneDeckView {
    /// Lyrics, Info, and Up Next keep the Display page's column, rows, and transport bar.
    var pageLayout: some View {
        VStack(spacing: 0) {
            DeckSafeRow(height: 90) {
                LEDDisplayView(player: player, height: 90, layout: .phoneStrip)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .clipShape(RoundedRectangle(cornerRadius: IPhoneDeckLayout.displayCornerRadius))
                    .padding(.horizontal, IPhoneDeckLayout.gutter)
            }
            DeckSafeContentRegion { _ in
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: IPhoneDeckLayout.cardCornerRadius))
                    .padding(.horizontal, IPhoneDeckLayout.gutter)
            }
            .padding(.vertical, IPhoneDeckLayout.groupSpacing)
            SeekBarView(player: player, drawsOnPanel: true)
                .padding(.horizontal, IPhoneDeckLayout.gutter)
            DeckSafeRow(height: IPhoneDeckLayout.rowHeight) {
                IPhoneTransportBar(player: player).padding(.horizontal, IPhoneDeckLayout.gutter)
            }
            .padding(.top, IPhoneDeckLayout.rowSpacing)
            .padding(.bottom, IPhoneDeckLayout.groupSpacing)
        }
    }

    var displayControls: some View {
        VStack(spacing: IPhoneDeckLayout.groupSpacing) {
            VStack(spacing: IPhoneDeckLayout.rowSpacing) {
                SeekBarView(player: player, drawsOnPanel: true)
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "phoneDeckSeek"))
                    #endif
                indicators
            }
            VStack(spacing: IPhoneDeckLayout.rowSpacing) {
                IPhoneTransportBar(player: player)
                volume
            }
        }
    }

    var pageSwitcher: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    ForEach(IPhoneDeckPage.allCases, id: \.self) { target in
                        Button {
                            page = target
                        } label: {
                            if page == target {
                                Label(L10n.string(String.LocalizationValue(target.rawValue)), systemImage: "checkmark")
                            } else {
                                Text(L10n.string(String.LocalizationValue(target.rawValue)))
                            }
                        }
                        .accessibilityIdentifier("phonePage.\(target.rawValue)")
                        .accessibilityAddTraits(page == target ? .isSelected : [])
                    }
                } label: {
                    Label(L10n.string(String.LocalizationValue(page.rawValue)), systemImage: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.enabledIcon)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: IPhoneDeckLayout.rowHeight)
                        .background(palette.normalButtonFill)
                        .iPhoneDeckControlFrame(palette)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Panel Content")
                .accessibilityValue(L10n.string(String.LocalizationValue(page.rawValue)))
                .accessibilityIdentifier("phonePageMenu")
            } else {
                pageButtons
            }
        }
        #if DEBUG
        .modifier(DuoPanelRegionDiagnostics(regionID: "phoneDeckPageSwitcher"))
        #endif
        .padding(.horizontal, IPhoneDeckLayout.gutter).padding(.bottom, IPhoneDeckLayout.bottomPadding)
    }

    var pageButtons: some View {
        IPhoneDeckCellRow {
            ForEach(Array(IPhoneDeckPage.allCases.enumerated()), id: \.element) { index, target in
                IPhoneDeckBarCell(isSelected: page == target, showsDivider: index > 0) { page = target } label: {
                    Text(L10n.string(String.LocalizationValue(target.rawValue)))
                        .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .accessibilityAddTraits(page == target ? .isSelected : [])
                .accessibilityIdentifier("phonePage.\(target.rawValue)")
            }
        }
        .frame(height: IPhoneDeckLayout.rowHeight)
        .iPhoneDeckControlFrame(palette)
    }

    /// Mute, the slot, and AirPlay; the level is shown over the slot only while dragging.
    var volume: some View {
        HStack(spacing: IPhoneDeckLayout.rowSpacing) {
            IPhoneTransportButton(
                title: player.isMuted ? "Unmute" : "Mute",
                symbol: player.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill", identifier: "phoneMute"
            ) { player.toggleMuted() }
            VolumeSlotView(
                value: player.volume, palette: palette, axis: .horizontal, showsValueWhileDragging: true
            ) { player.setVolume($0) }
                .frame(height: IPhoneDeckLayout.rowHeight)
            IPhoneRouteButton()
        }
    }

    var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }

    var pitchSpeedAvailable: Bool { player.isVideoMode == false }

    var queuePlaybackState: String {
        if player.isPlaying { return L10n.string("Playing") }
        return player.isPaused ? L10n.string("Paused") : L10n.string("Stopped")
    }

    var moreMenu: some ToolbarContent {
        let isLibraryItem = player.currentItem?.isInLibrary == true
        return ToolbarOverflowMenu {
            Button("Save adjusted copy", systemImage: "square.and.arrow.down") { saveItem = player.currentItem }
                .disabled(player.isVideoMode || !player.hasPitchOrRateAdjustment || !isLibraryItem)
            Button("Create AAC Version", systemImage: "waveform.badge.plus") {
                if let item = player.currentItem { createAACVersion(item) }
            }
            .disabled(player.isVideoMode || !canCreateAACVersion || !isLibraryItem)
            Button("Edit Information…", systemImage: "pencil") { infoItem = player.currentItem }
                .disabled(!isLibraryItem)
        }
    }
}
#endif

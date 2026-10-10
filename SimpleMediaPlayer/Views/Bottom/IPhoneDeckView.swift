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

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 12) {
                    if page == .display {
                        if usesExpandedDisplay(in: proxy) {
                            expandedDisplay(size: proxy.size)
                        } else {
                            IPhoneDeckArrangementView { height in
                                display(height: height)
                            } controls: {
                                VStack(spacing: 18) {
                                    SeekBarView(player: player).frame(minHeight: 44)
                                    indicators
                                    transport(large: true)
                                    volume
                                }
                            }
                        }
                    } else {
                        DeckSafeRow(height: 90) {
                            LEDDisplayView(player: player, height: 90, layout: .phoneStrip)
                                .clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
                        }
                        pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                        SeekBarView(player: player).frame(minHeight: 44)
                        DeckSafeRow(height: 52) { transport(large: false).padding(.horizontal, 16) }
                    }
                    DeckSafeRow(height: dynamicTypeSize.isAccessibilitySize ? 72 : 52) { pageSwitcher }
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
        .sheet(item: $infoItem) { item in MediaInfoView(item: item, libraryService: libraryService) }
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
                .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("phoneDeckClose")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if page == .lyrics {
                Button("Edit Lyrics…", systemImage: "square.and.pencil") { lyricsItem = libraryCurrentItem }
                    .disabled(libraryCurrentItem == nil || player.isVideoMode)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                moreMenu
            }
        }
    }

    @ViewBuilder private func display(height: CGFloat) -> some View {
        if player.isVideoMode {
            VideoAreaView(player: player, showsBackToListButton: false,
                          presentVideoFullScreen: { showsVideoFullScreen = true })
                .frame(height: height).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            LEDDisplayView(
                player: player, height: height, visualizerHeight: min(88, max(20, height - 180)),
                layout: height < 200 ? .phoneStrip : .phoneDeck
            )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(5).background(palette.displayBezelFill, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .lyrics, .info:
            LyricsPanelView(
                item: player.currentItem,
                listIndex: player.queue.firstIndex(where: { $0.id == player.currentItem?.id }).map { $0 + 1 },
                libraryService: libraryService, page: page == .lyrics ? .lyrics : .information,
                playbackPlayer: player
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
        case .display: EmptyView()
        }
    }

    private var indicators: some View {
        HStack(spacing: 12) {
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
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(active ? palette.indicatorLEDOn : palette.indicatorLEDOff)
                        .frame(width: 7, height: 7).shadow(color: active ? palette.indicatorLEDGlow : .clear, radius: 4)
                    Text(title).font(.caption.weight(.bold))
                }
                Text(value).font(.caption.monospacedDigit()).lineLimit(1)
            }
            .foregroundStyle(palette.labelColor)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(palette.normalButtonFill, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(String.LocalizationValue(label))).accessibilityValue(value)
        .accessibilityHint("Open playback adjustments")
        .accessibilityIdentifier("phoneLamp.\(title)")
    }

    private func transport(large: Bool) -> some View {
        HStack(spacing: 10) {
            IPhoneTransportButton(title: "Stop", symbol: "stop.fill", identifier: "phoneStop") { player.stop() }
            IPhoneTransportButton(title: "Previous Track", symbol: "backward.end.fill", identifier: "phonePrevious") {
                player.previous()
            }.disabled(!player.canPlayPrevious)
            IPhoneTransportButton(
                title: player.isPlaying ? "Pause" : "Play", symbol: player.isPlaying ? "pause.fill" : "play.fill",
                identifier: "phonePlayPause", size: large ? 76 : 52
            ) { player.togglePlayPause() }
            IPhoneTransportButton(title: "Next Track", symbol: "forward.end.fill", identifier: "phoneNext") {
                player.next()
            }.disabled(!player.canSkipToNext)
            IPhoneRoutePicker().frame(width: 44, height: 44)
        }.frame(maxWidth: .infinity)
    }
}

private extension IPhoneDeckView {
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
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
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
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    var pageButtons: some View {
        HStack(spacing: 0) {
            ForEach(IPhoneDeckPage.allCases, id: \.self) { target in
                Button { page = target } label: {
                    Text(L10n.string(String.LocalizationValue(target.rawValue)))
                        .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if page == target { RoundedRectangle(cornerRadius: 8).fill(palette.normalButtonFill) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == target ? .isSelected : [])
                .accessibilityIdentifier("phonePage.\(target.rawValue)")
            }
        }
    }

    var volume: some View {
        HStack(spacing: 12) {
            IPhoneTransportButton(
                title: player.isMuted ? "Unmute" : "Mute",
                symbol: player.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill", identifier: "phoneMute"
            ) { player.toggleMuted() }
            VolumeSlotView(value: player.volume, palette: palette, axis: .horizontal) { player.setVolume($0) }
                .frame(height: 44)
            Text("\(Int(player.volume * 100))").font(.caption.monospacedDigit()).frame(width: 30)
        }
    }

    var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }

    var pitchSpeedAvailable: Bool { player.isVideoMode == false }

    var queuePlaybackState: String {
        if player.isPlaying { return L10n.string("Playing") }
        return player.isPaused ? L10n.string("Paused") : L10n.string("Stopped")
    }

    var moreMenu: some View {
        let isLibraryItem = player.currentItem?.isInLibrary == true
        return Menu {
            Button { saveItem = player.currentItem } label: {
                menuLabel("Save adjusted copy", systemImage: "square.and.arrow.down")
            }.disabled(player.isVideoMode || !player.hasPitchOrRateAdjustment || !isLibraryItem)
            Button {
                if let item = player.currentItem { createAACVersion(item) }
            } label: {
                menuLabel("Create AAC Version", systemImage: "waveform.badge.plus")
            }.disabled(player.isVideoMode || !canCreateAACVersion || !isLibraryItem)
            Button { infoItem = player.currentItem } label: {
                menuLabel("Edit Information…", systemImage: "pencil")
            }.disabled(!isLibraryItem)
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("phoneDeckMore")
    }

    func menuLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
#endif

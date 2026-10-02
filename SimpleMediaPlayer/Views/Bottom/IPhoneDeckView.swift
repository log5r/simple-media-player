#if os(iOS)
import AVKit
import SwiftData
import SwiftUI

struct IPhoneLEDDock: View {
    let player: PlayerViewModel
    let openDeck: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openDeck) {
                LEDDisplayView(player: player, height: 66, layout: .phoneDock)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing")
            .accessibilityValue(player.currentItem?.title ?? "")
            .accessibilityHint("Open the playback deck")
            .accessibilityIdentifier("phoneLEDDock")
            IPhoneTransportButton(
                title: player.isPlaying ? "Pause" : "Play",
                symbol: player.isPlaying ? "pause.fill" : "play.fill", identifier: "phoneDockPlayPause"
            ) { player.togglePlayPause() }
            IPhoneTransportButton(title: "Next Track", symbol: "forward.end.fill", identifier: "phoneDockNext") {
                player.next()
            }.disabled(!player.canSkipToNext)
        }
        .background(BottomPanelPalette(colorScheme: colorScheme).panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var page = IPhoneDeckPage.display
    @State private var showsAdjustments = false
    @State private var infoItem: MediaItem?
    @State private var lyricsItem: MediaItem?
    @State private var saveItem: MediaItem?
    @State private var pendingSaveItem: MediaItem?

    private var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }

    private var pitchSpeedAvailable: Bool { player.isVideoMode == false }

    private var queuePlaybackState: String {
        if player.isPlaying { return L10n.string("Playing") }
        return player.isPaused ? L10n.string("Paused") : L10n.string("Stopped")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if page == .display {
                    ScrollView {
                        VStack(spacing: 18) {
                            display
                            SeekBarView(player: player).frame(minHeight: 44)
                            indicators
                            transport(large: true)
                            volume
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                    }
                } else {
                    LEDDisplayView(player: player, height: 90, layout: .phoneStrip)
                        .clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
                    pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    SeekBarView(player: player).frame(minHeight: 44)
                    transport(large: false).padding(.horizontal, 16)
                }
                pageSwitcher
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
                pendingSaveItem = player.currentItem
                showsAdjustments = false
            }
            .presentationDetents([.medium, .large])
        })
        .sheet(item: $infoItem) { item in MediaInfoView(item: item, libraryService: libraryService) }
        .sheet(item: $lyricsItem) { item in LyricsEditorView(item: item, libraryService: libraryService) }
        .sheet(item: $saveItem) { item in
            SaveTransformedCopyView(
                item: item, player: player, libraryService: libraryService, modelContext: modelContext,
                onComplete: { _ in saveItem = nil }, onCancel: { saveItem = nil }
            )
        }
        .alert("Create AAC Version", isPresented: Binding(
            get: { showsAACResult && isPresented },
            set: { if !$0 && isPresented { showsAACResult = false } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(aacResultMessage) }
        .onChange(of: player.currentItem?.id) { _, id in
            if id == nil { isPresented = false }
        }
    }

    private var pageSwitcher: some View {
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
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    @ToolbarContentBuilder private var deckToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "chevron.down") { isPresented = false }
                .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("phoneDeckClose")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if page == .lyrics {
                Button("Edit Lyrics…", systemImage: "square.and.pencil") { lyricsItem = player.currentItem }
                    .disabled(player.currentItem == nil || player.isVideoMode)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                moreMenu
            }
        }
    }

    @ViewBuilder private var display: some View {
        if player.isVideoMode {
            VideoAreaView(player: player, showsBackToListButton: false)
                .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            LEDDisplayView(player: player, height: 300, visualizerHeight: 88, layout: .phoneDeck)
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
                playbackTime: player.currentTime
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
            }.disabled(!player.canSkipToPrevious && player.currentTime < 3)
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

    private var volume: some View {
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
}

struct IPhoneTransportButton: View {
    let title: String
    let symbol: String
    let identifier: String
    var size: CGFloat = 44
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let palette = BottomPanelPalette(colorScheme: colorScheme)
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size > 52 ? 28 : 18, weight: .semibold))
                .foregroundStyle(isEnabled ? palette.enabledIcon : palette.disabledIcon)
                .frame(width: size, height: size)
                .background(palette.normalButtonFill, in: Circle())
                .overlay(Circle().stroke(palette.controlStroke, lineWidth: 1))
                .shadow(color: palette.buttonShadow, radius: 2, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(String.LocalizationValue(title))).accessibilityIdentifier(identifier)
    }
}

private struct IPhoneRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.accessibilityLabel = L10n.string("Output Device")
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private extension IPhoneDeckView {
    var moreMenu: some View {
        Menu {
            Button { saveItem = player.currentItem } label: {
                menuLabel("Save adjusted copy", systemImage: "square.and.arrow.down")
            }.disabled(player.isVideoMode || !player.hasPitchOrRateAdjustment)
            Button {
                if let item = player.currentItem { createAACVersion(item) }
            } label: {
                menuLabel("Create AAC Version", systemImage: "waveform.badge.plus")
            }.disabled(player.isVideoMode || !canCreateAACVersion)
            Button { infoItem = player.currentItem } label: {
                menuLabel("Edit Information…", systemImage: "pencil")
            }
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

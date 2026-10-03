#if os(iOS)
import SwiftUI

struct DuoPortraitPlayerView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let queue: [MediaItem]
    let playItem: (MediaItem) -> Void
    let requestSaveCopy: (MediaItem) -> Void
    let showLibrary: () -> Void
    let showSettings: () -> Void
    let showEqualizer: () -> Void
    let showDetails: () -> Void
    let showVideoFullScreen: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppSettingsKey.ledPanelCorner) private var cornerRaw = AppSettingsDefault.ledPanelCorner

    private var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }
    private var corner: LEDPanelCorner { LEDPanelCorner(rawValue: cornerRaw) ?? .adaptive }

    var body: some View {
        GeometryReader { proxy in
            let placement = DuoPortraitPlayerPlacement.make(
                in: CGRect(origin: .zero, size: proxy.size),
                divisionFrames: DeckReservedRegions.activeDivisionFrames(in: proxy),
                reservedFrames: DeckReservedRegions.activeFrames(in: proxy)
            )
            ZStack(alignment: .topLeading) {
                meters
                    .padding(10)
                    .frame(width: placement.meters.width, height: placement.meters.height)
                    .clipped()
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "duoPortraitMeters"))
                    #endif
                    .offset(x: placement.meters.minX, y: placement.meters.minY)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Level meter")
                    .accessibilityIdentifier("duoPortraitMeters")
                display(size: placement.led.size)
                    .frame(width: placement.led.width, height: placement.led.height)
                    .clipped()
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "duoPortraitLED"))
                    #endif
                    .offset(x: placement.led.minX, y: placement.led.minY)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Display")
                    .accessibilityIdentifier("duoPortraitLED")
                controls(size: placement.controls.size)
                    .frame(width: placement.controls.width, height: placement.controls.height)
                    .clipped()
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "duoPortraitControls"))
                    #endif
                    .offset(x: placement.controls.minX, y: placement.controls.minY)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Panel Content")
                    .accessibilityIdentifier("duoPortraitControls")
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now Playing")
            .accessibilityIdentifier("duoPortraitPlayer")
        }
        .background(palette.panelBackground)
    }

    private var meters: some View {
        HStack(spacing: 8) {
            IndicatorColumnView(player: player, palette: palette)
            VUMeterView(player: player, channel: .left)
                .accessibilityIdentifier("duoPortraitMeterL")
            VUMeterView(player: player, channel: .right)
                .accessibilityIdentifier("duoPortraitMeterR")
        }
    }

    private func display(size: CGSize) -> some View {
        let height = max(1, size.height - 17)
        return LEDBezelPlate(corner: corner, side: .right, palette: palette) { shape in
            LEDDisplayView(
                player: player, height: height, visualizerHeight: max(20, height - 95),
                cornerShape: shape, alignsContentToBottom: true,
                informationScale: 1.2, emphasizesTitle: true, auxiliaryInformationScale: 1
            )
        }
        .padding(7)
    }

    private func controls(size: CGSize) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 14) {
                SeekBarView(player: player)
                AdaptiveBottomControlsView(
                    player: player, selectedItem: selectedItem, queue: queue, palette: palette,
                    width: max(AdaptiveBottomPanelMetrics.minimumControlWidth, size.width - 24),
                    layout: .ledHalf, playItem: playItem, requestSaveCopy: requestSaveCopy, showsMeters: false,
                    showsOutputControls: true
                )
                actions
            }
            .padding(12)
            .frame(width: max(356, size.width))
            .frame(minHeight: size.height)
        }
        .scrollIndicators(.hidden)
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) :
            AnyLayout(HStackLayout(spacing: 8))
        return layout {
            action("Library", symbol: "music.note.list", identifier: "duoShowLibrary", perform: showLibrary)
            action("Equalizer", symbol: "slider.horizontal.3", identifier: "equalizerButton", perform: showEqualizer)
            action("Details", symbol: "info.circle", identifier: "lyricsButton", perform: showDetails)
            if player.isVideoMode {
                action("Show Video", symbol: "play.rectangle", identifier: "showVideoButton",
                       perform: showVideoFullScreen)
            }
            action("Settings", symbol: "gearshape", identifier: "settingsButton", perform: showSettings)
        }
    }

    private func action(
        _ title: LocalizedStringKey, symbol: String, identifier: String, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(palette.normalButtonFill, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}
#endif

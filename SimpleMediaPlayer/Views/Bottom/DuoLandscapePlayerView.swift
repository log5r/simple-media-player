#if os(iOS)
import SwiftUI

struct DuoLandscapePlayerView: View {
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
    @AppStorage(AppSettingsKey.ledPanelCorner) private var cornerRaw = AppSettingsDefault.ledPanelCorner

    private var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }
    private var corner: LEDPanelCorner { LEDPanelCorner(rawValue: cornerRaw) ?? .adaptive }

    var body: some View {
        GeometryReader { proxy in
            let placement = AdaptiveBottomPanelPlacement.make(
                in: CGRect(origin: .zero, size: proxy.size),
                avoiding: DeckReservedRegions.activeFrames(in: proxy), side: .right, layout: .ledHalf
            )
            ZStack(alignment: .topLeading) {
                display(size: placement.display.size)
                    .frame(width: placement.display.width, height: placement.display.height)
                    .clipped()
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "expandedLEDRegion"))
                    #endif
                    .offset(x: placement.display.minX, y: placement.display.minY)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Display")
                    .accessibilityIdentifier("expandedLEDRegion")
                controls(size: placement.controls.size)
                    .frame(width: placement.controls.width, height: placement.controls.height)
                    .clipped()
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "expandedControlsRegion"))
                    #endif
                    .offset(x: placement.controls.minX, y: placement.controls.minY)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Panel Content")
                    .accessibilityIdentifier("expandedControlsRegion")
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now Playing")
            .accessibilityIdentifier("duoLandscapePlayer")
        }
        .background(palette.panelBackground)
    }

    private func display(size: CGSize) -> some View {
        let height = max(1, size.height - 17)
        return LEDBezelPlate(corner: corner, side: .right, palette: palette) { shape in
            LEDDisplayView(
                player: player, height: height, visualizerHeight: max(20, height - 192),
                cornerShape: shape, layout: height >= 230 ? .phoneDeck : .standard
            )
        }
        .padding(7)
    }

    private func controls(size: CGSize) -> some View {
        let contentWidth = max(AdaptiveBottomPanelMetrics.minimumControlWidth, size.width)
        return ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 12) {
                SeekBarView(player: player).padding(.horizontal, 12)
                AdaptiveBottomControlsView(
                    player: player, selectedItem: selectedItem, queue: queue, palette: palette,
                    width: contentWidth,
                    layout: .ledHalf, playItem: playItem, requestSaveCopy: requestSaveCopy, showsOutputControls: true
                )
                actions.padding(.horizontal, 12)
            }
            .padding(.vertical, 12)
            .frame(width: contentWidth)
            .frame(minHeight: size.height)
        }
        .scrollIndicators(.hidden)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                action("Library", symbol: "music.note.list", identifier: "duoShowLibrary", perform: showLibrary)
                action("Settings", symbol: "gearshape", identifier: "settingsButton", perform: showSettings)
            }
            HStack(spacing: 8) {
                action("Equalizer", symbol: "slider.horizontal.3", identifier: "equalizerButton",
                       perform: showEqualizer)
                action("Details", symbol: "info.circle", identifier: "lyricsButton", perform: showDetails)
            }
            if player.isVideoMode {
                action("Show Video", symbol: "play.rectangle", identifier: "showVideoButton",
                       perform: showVideoFullScreen)
            }
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

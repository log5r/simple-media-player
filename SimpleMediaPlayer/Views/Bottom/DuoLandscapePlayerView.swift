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
        // The plate's trailing edge meets the page switcher's 16 pt edge below it.
        .padding(.vertical, 7)
        .padding(.leading, IPhoneDeckLayout.gutter / 2).padding(.trailing, IPhoneDeckLayout.gutter)
    }

    /// The column's leading edge matches the page switcher; half a gutter on each side separates it from the LED.
    private func controls(size: CGSize) -> some View {
        let inset = IPhoneDeckLayout.gutter + IPhoneDeckLayout.gutter / 2
        let contentWidth = max(AdaptiveBottomPanelMetrics.minimumControlWidth, size.width - inset)
        return ScrollView([.horizontal, .vertical]) {
            VStack(spacing: IPhoneDeckLayout.rowSpacing) {
                SeekBarView(player: player, drawsOnPanel: true)
                AdaptiveBottomControlsView(
                    player: player, selectedItem: selectedItem, queue: queue, palette: palette,
                    width: contentWidth, layout: .ledHalf, playItem: playItem, requestSaveCopy: requestSaveCopy,
                    showsOutputControls: true, usesDeckVolumeRow: true
                )
                DuoNavigationButtons(
                    isVideoMode: player.isVideoMode, showLibrary: showLibrary, showEqualizer: showEqualizer,
                    showDetails: showDetails, showVideoFullScreen: showVideoFullScreen, showSettings: showSettings
                )
            }
            .frame(width: contentWidth)
            .padding(.vertical, IPhoneDeckLayout.gutter)
            .padding(.leading, IPhoneDeckLayout.gutter).padding(.trailing, IPhoneDeckLayout.gutter / 2)
            .frame(minHeight: size.height)
        }
        .scrollIndicators(.hidden)
    }
}
#endif

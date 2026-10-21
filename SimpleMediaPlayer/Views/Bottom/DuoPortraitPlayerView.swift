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
    /// The folded Library covers the lower half, so its controls are not drawn underneath.
    var showsControls = true

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettingsKey.ledPanelCorner) private var cornerRaw = AppSettingsDefault.ledPanelCorner
    @State private var controlsContentHeight: CGFloat = 0

    private var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }
    private var corner: LEDPanelCorner { LEDPanelCorner(rawValue: cornerRaw) ?? .adaptive }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            // A partially folded display keeps the visuals above the fold; a flat one gives them the spare height.
            let isFolded = DuoPortraitPlayerLayout.foldBottom(
                in: bounds, divisionFrames: DeckReservedRegions.activeDivisionFrames(in: proxy)
            ) != nil
            let placement = DuoPortraitPlayerPlacement.make(
                in: bounds,
                occlusionFrames: DeckReservedRegions.activeFrames(in: proxy, includesDivisions: false),
                controlsHeight: showsControls && !isFolded && controlsContentHeight > 0 ? controlsContentHeight : nil
            )
            ZStack(alignment: .topLeading) {
                meters
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
                if showsControls {
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
        .padding(.vertical, 10).padding(.horizontal, IPhoneDeckLayout.gutter)
    }

    private func display(size: CGSize) -> some View {
        let height = max(1, size.height - 17)
        return LEDBezelPlate(corner: corner, side: .right, palette: palette, meetsWindowCorner: false) { shape in
            LEDDisplayView(
                player: player, height: height, visualizerHeight: max(20, height - 95),
                cornerShape: shape, alignsContentToBottom: true,
                informationScale: 1.2, emphasizesTitle: true, auxiliaryInformationScale: 1
            )
        }
        #if DEBUG
        .modifier(DuoPanelRegionDiagnostics(regionID: "duoPortraitLEDPlate"))
        #endif
        .padding(.vertical, 7).padding(.horizontal, IPhoneDeckLayout.gutter)
    }

    /// The seek row starts 16 pt below the controls' top edge and the rows follow 8 pt apart.
    private func controls(size: CGSize) -> some View {
        let width = max(AdaptiveBottomPanelMetrics.minimumControlWidth + 2 * IPhoneDeckLayout.gutter, size.width)
        return ScrollView([.horizontal, .vertical]) {
            VStack(spacing: IPhoneDeckLayout.rowSpacing) {
                SeekBarView(player: player, avoidsDisplayDivision: false, drawsOnPanel: true)
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "duoPortraitSeek"))
                    #endif
                AdaptiveBottomControlsView(
                    player: player, selectedItem: selectedItem, queue: queue, palette: palette,
                    width: width - 2 * IPhoneDeckLayout.gutter,
                    layout: .ledHalf, playItem: playItem, requestSaveCopy: requestSaveCopy, showsMeters: false,
                    showsOutputControls: true, usesDeckVolumeRow: true
                )
                DuoNavigationButtons(
                    isVideoMode: player.isVideoMode, showLibrary: showLibrary, showEqualizer: showEqualizer,
                    showDetails: showDetails, showVideoFullScreen: showVideoFullScreen, showSettings: showSettings
                )
            }
            .padding(IPhoneDeckLayout.gutter)
            .frame(width: width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsContentHeight = $0 }
            .frame(minHeight: size.height, alignment: .top)
        }
        .scrollIndicators(.hidden)
    }
}
#endif

#if os(iOS)
import SwiftUI

struct AdaptiveBottomPanelView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let queue: [MediaItem]
    let playItem: (MediaItem) -> Void
    let requestSaveCopy: (MediaItem) -> Void
    let layout: BottomPanelLayout
    let availableWidth: CGFloat?

    @AppStorage(AppSettingsKey.ledPanelSide) private var sideRaw = AppSettingsDefault.ledPanelSide
    @AppStorage(AppSettingsKey.ledPanelCorner) private var cornerRaw = AppSettingsDefault.ledPanelCorner
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.usesDividedDisplay) private var usesDividedDisplay
    @State private var measuredWidth: CGFloat = 0
    @State private var dividedControlWidth: CGFloat?

    private var panelSide: LEDPanelSide { LEDPanelSide(rawValue: sideRaw) ?? .right }
    private var panelCorner: LEDPanelCorner { LEDPanelCorner(rawValue: cornerRaw) ?? .adaptive }
    private var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }
    private var width: CGFloat { max(1, availableWidth ?? measuredWidth) }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let displaySide: LEDPanelSide = DeckReservedRegions.hasDisplayDivision(in: proxy) ? .right : panelSide
            let placement = AdaptiveBottomPanelPlacement.make(
                in: bounds, avoiding: DeckReservedRegions.activeFrames(in: proxy),
                side: displaySide, layout: layout
            )
            let regionControlWidth = placement.controlWidthForVerticalDivision(
                in: bounds, divisionFrames: DeckReservedRegions.activeDivisionFrames(in: proxy)
            )
            ZStack(alignment: .topLeading) {
                display(in: placement.display, side: displaySide)
                    .frame(width: placement.display.width, height: placement.display.height)
                    .clipped()
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "expandedLEDRegion"))
                    #endif
                    .offset(x: placement.display.minX, y: placement.display.minY)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Display")
                    .accessibilityIdentifier("expandedLEDRegion")
                controls(in: placement.controls)
                    .frame(width: placement.controls.width, height: placement.controls.height)
                    .contentShape(Rectangle())
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
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
            .onChange(of: regionControlWidth, initial: true) { _, value in dividedControlWidth = value }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now Playing")
            .accessibilityIdentifier("expandedBottomPanel")
        }
        .frame(height: AdaptiveBottomPanelMetrics.height(width: width, layout: layout,
                                                       dividedControlWidth: dividedControlWidth,
                                                       showsOutputControls: usesDividedDisplay))
        .background(palette.panelBackground)
        .overlay(alignment: .top) { Rectangle().fill(palette.panelTopStroke).frame(height: 1) }
    }

    private func display(in region: CGRect, side: LEDPanelSide) -> some View {
        let displayHeight = max(1, region.height - 17)
        return LEDBezelPlate(corner: panelCorner, side: side, palette: palette) { shape in
            LEDDisplayView(
                player: player, height: displayHeight,
                visualizerHeight: layout == .classic ? 40 : max(20, displayHeight - 95), cornerShape: shape,
                alignsContentToBottom: layout == .ledHalf && displayHeight >= 130,
                informationScale: layout == .ledHalf && displayHeight >= 130 ? 1.2 : 1,
                emphasizesTitle: layout == .ledHalf, auxiliaryInformationScale: 1,
                layout: displayHeight < 100 ? .phoneStrip : .standard
            )
        }
        .padding(7)
    }

    private func controls(in region: CGRect) -> some View {
        ScrollView([.horizontal, .vertical]) {
            AdaptiveBottomControlsView(
                player: player, selectedItem: selectedItem, queue: queue, palette: palette,
                width: max(AdaptiveBottomPanelMetrics.minimumControlWidth, region.width),
                layout: layout, playItem: playItem, requestSaveCopy: requestSaveCopy,
                showsOutputControls: usesDividedDisplay
            )
        }
        .scrollIndicators(.hidden)
    }
}

#endif

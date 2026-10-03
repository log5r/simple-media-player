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
    @State private var measuredWidth: CGFloat = 0
    @State private var dividedControlWidth: CGFloat?

    private var panelSide: LEDPanelSide { LEDPanelSide(rawValue: sideRaw) ?? .right }
    private var panelCorner: LEDPanelCorner { LEDPanelCorner(rawValue: cornerRaw) ?? .adaptive }
    private var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }
    private var width: CGFloat { max(1, availableWidth ?? measuredWidth) }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let placement = AdaptiveBottomPanelPlacement.make(
                in: bounds, avoiding: DeckReservedRegions.activeFrames(in: proxy),
                side: panelSide, layout: layout
            )
            let regionControlWidth = placement.controlWidthForVerticalDivision(
                in: bounds, divisionFrames: DeckReservedRegions.activeDivisionFrames(in: proxy)
            )
            ZStack(alignment: .topLeading) {
                display(in: placement.display)
                    .frame(width: placement.display.width, height: placement.display.height)
                    .clipped()
                    .offset(x: placement.display.minX, y: placement.display.minY)
                controls(in: placement.controls)
                    .frame(width: placement.controls.width, height: placement.controls.height)
                    .contentShape(Rectangle())
                    .clipped()
                    .offset(x: placement.controls.minX, y: placement.controls.minY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
            .onChange(of: regionControlWidth, initial: true) { _, value in dividedControlWidth = value }
        }
        .frame(height: AdaptiveBottomPanelMetrics.height(width: width, layout: layout,
                                                       dividedControlWidth: dividedControlWidth))
        .background(palette.panelBackground)
        .overlay(alignment: .top) { Rectangle().fill(palette.panelTopStroke).frame(height: 1) }
        .accessibilityIdentifier("expandedBottomPanel")
    }

    private func display(in region: CGRect) -> some View {
        let displayHeight = max(1, region.height - 17)
        return LEDBezelPlate(corner: panelCorner, side: panelSide, palette: palette) { shape in
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
                layout: layout, playItem: playItem, requestSaveCopy: requestSaveCopy
            )
        }
        .scrollIndicators(.hidden)
    }
}

private struct AdaptiveBottomControlsView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let queue: [MediaItem]
    let palette: BottomPanelPalette
    let width: CGFloat
    let layout: BottomPanelLayout
    let playItem: (MediaItem) -> Void
    let requestSaveCopy: (MediaItem) -> Void

    private var usesInlineControls: Bool { width >= AdaptiveBottomPanelMetrics.inlineControlWidth }

    var body: some View {
        Group {
            if usesInlineControls {
                inlineControls
            } else {
                stackedControls
            }
        }
        .padding(14)
        .frame(width: width, height: AdaptiveBottomPanelMetrics.controlHeight(width: width, layout: layout))
    }

    private var inlineControls: some View {
        HStack(spacing: 12) {
            VolumeControlView(player: player, palette: palette)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    adjustments
                    transport
                }
                if layout == .ledHalf { meters }
            }
        }
    }

    private var stackedControls: some View {
        VStack(spacing: 12) {
            transport
            HStack(spacing: 12) {
                adjustments
                horizontalVolume
            }
            if layout == .ledHalf { meters }
        }
    }

    private var adjustments: some View {
        PitchSpeedControlsView(player: player, selectedItem: selectedItem, palette: palette,
                               requestSaveCopy: requestSaveCopy)
    }

    private var transport: some View {
        TransportButtonsView(player: player, selectedItem: selectedItem, queue: queue,
                             palette: palette, playItem: playItem)
            .frame(minWidth: AdaptiveBottomPanelMetrics.minimumTransportWidth)
    }

    private var meters: some View {
        HStack(spacing: 8) {
            IndicatorColumnView(player: player, palette: palette)
            VUMeterView(player: player, channel: .left)
            VUMeterView(player: player, channel: .right)
        }
        .frame(height: 96)
    }

    private var horizontalVolume: some View {
        HStack(spacing: 8) {
            volumeButton(label: "Volume Down", symbol: "minus", identifier: "volumeDownButton") {
                player.setVolume(player.volume - 0.1)
            }
            VolumeSlotView(value: player.volume, palette: palette, axis: .horizontal) { player.setVolume($0) }
                .frame(minWidth: 44, minHeight: 44)
            volumeButton(label: "Volume Up", symbol: "plus", identifier: "volumeUpButton") {
                player.setVolume(player.volume + 0.1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("volumeControl")
    }

    private func volumeButton(
        label: LocalizedStringKey, symbol: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .black))
                .foregroundStyle(palette.enabledIcon)
                .frame(width: 44, height: 44)
                .background(palette.normalButtonFill, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.controlStroke, lineWidth: 1))
        }
        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
        .accessibilityValue(L10n.format("%d percent", Int(player.volume * 100)))
    }
}
#endif

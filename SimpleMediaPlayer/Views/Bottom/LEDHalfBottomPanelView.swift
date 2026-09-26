import SwiftUI

struct LEDHalfBottomPanelView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let queue: [MediaItem]
    let playItem: (MediaItem) -> Void
    let requestSaveCopy: (MediaItem) -> Void

    @AppStorage(AppSettingsKey.ledPanelSide) private var sideRaw = AppSettingsDefault.ledPanelSide
    @AppStorage(AppSettingsKey.ledPanelCorner) private var cornerRaw = AppSettingsDefault.ledPanelCorner
    @Environment(\.colorScheme) private var colorScheme

    private var panelSide: LEDPanelSide {
        LEDPanelSide(rawValue: sideRaw) ?? .right
    }

    private var panelCorner: LEDPanelCorner {
        LEDPanelCorner(rawValue: cornerRaw) ?? .adaptive
    }

    var body: some View {
        GeometryReader { proxy in
            let halfWidth = proxy.size.width / 2
            let transportWidth = BottomPanelMetrics.classicTransportWidth(for: proxy.size.width)
            let palette = BottomPanelPalette(colorScheme: colorScheme)

            HStack(spacing: 0) {
                if panelSide == .left {
                    ledHalf(palette: palette)
                        .frame(width: halfWidth)
                    controlHalf(palette: palette, transportWidth: transportWidth)
                        .frame(width: halfWidth)
                } else {
                    controlHalf(palette: palette, transportWidth: transportWidth)
                        .frame(width: halfWidth)
                    ledHalf(palette: palette)
                        .frame(width: halfWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.panelBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.panelTopStroke).frame(height: 1)
            }
        }
        .frame(height: 170)
    }

    private func ledHalf(palette: BottomPanelPalette) -> some View {
        LEDBezelPlate(
            corner: panelCorner,
            side: panelSide,
            palette: palette
        ) { innerCornerShape in
            LEDDisplayView(
                player: player,
                height: 153,
                visualizerHeight: 58,
                cornerShape: innerCornerShape,
                alignsContentToBottom: true,
                informationScale: 1.2,
                emphasizesTitle: true,
                auxiliaryInformationScale: 1
            )
        }
        .padding(7)
    }

    private func controlHalf(palette: BottomPanelPalette, transportWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if panelSide == .right {
                volumeControl(palette: palette)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    PitchSpeedControlsView(
                        player: player,
                        selectedItem: selectedItem,
                        palette: palette,
                        requestSaveCopy: requestSaveCopy
                    )

                    TransportButtonsView(
                        player: player,
                        selectedItem: selectedItem,
                        queue: queue,
                        palette: palette,
                        playItem: playItem
                    )
                    .frame(width: transportWidth)
                }

                // 上段と同じ幅に揃えたインジケーター列 + VU メーター(高さ 96 = 142 − 34 − 12)
                HStack(spacing: 12) {
                    IndicatorColumnView(player: player, palette: palette)

                    HStack(spacing: 8) {
                        VUMeterView(player: player, channel: .left)
                        VUMeterView(player: player, channel: .right)
                    }
                }
                .frame(width: 96 + 12 + transportWidth, height: 96)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if panelSide == .left {
                volumeControl(palette: palette)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func volumeControl(palette: BottomPanelPalette) -> some View {
        VolumeControlView(player: player, palette: palette)
    }
}

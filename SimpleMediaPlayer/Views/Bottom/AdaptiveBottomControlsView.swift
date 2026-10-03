#if os(iOS)
import SwiftUI

struct AdaptiveBottomControlsView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let queue: [MediaItem]
    let palette: BottomPanelPalette
    let width: CGFloat
    let layout: BottomPanelLayout
    let playItem: (MediaItem) -> Void
    let requestSaveCopy: (MediaItem) -> Void
    var showsMeters = true
    var showsOutputControls = false

    private var usesInlineControls: Bool { width >= AdaptiveBottomPanelMetrics.inlineControlWidth }
    private var combinesAdjustmentAndTransport: Bool { width >= AdaptiveBottomPanelMetrics.combinedButtonsWidth }

    var body: some View {
        Group {
            if layout == .ledHalf {
                compactControls.padding(8)
            } else if usesInlineControls {
                inlineControls.padding(14)
            } else {
                stackedControls.padding(14)
            }
        }
        .frame(width: width, height: AdaptiveBottomPanelMetrics.controlHeight(
            width: width, layout: layout, showsMeters: showsMeters, showsOutputControls: showsOutputControls
        ))
    }

    private var compactControls: some View {
        VStack(spacing: AdaptiveBottomPanelMetrics.compactSpacing) {
            if combinesAdjustmentAndTransport {
                HStack(spacing: AdaptiveBottomPanelMetrics.compactSpacing) {
                    adjustments
                    transport
                }
            } else {
                transport
            }
            HStack(spacing: AdaptiveBottomPanelMetrics.compactSpacing) {
                if !combinesAdjustmentAndTransport { adjustments }
                horizontalVolume.frame(width: compactVolumeWidth)
                if showsOutputControls && combinesAdjustmentAndTransport { outputControls }
            }
            .frame(maxWidth: .infinity)
            if showsOutputControls && !combinesAdjustmentAndTransport { outputControls }
            if showsMeters { meters }
        }
    }

    private var compactVolumeWidth: CGFloat {
        if combinesAdjustmentAndTransport { return min(188, width - 16) }
        return width - 16 - BottomPanelMetrics.adjustmentWidth - AdaptiveBottomPanelMetrics.compactSpacing
    }

    private var outputControls: some View {
        HStack(spacing: AdaptiveBottomPanelMetrics.compactSpacing) {
            IPhoneTransportButton(
                title: player.isMuted ? "Unmute" : "Mute",
                symbol: player.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill", identifier: "phoneMute"
            ) { player.toggleMuted() }
            IPhoneRoutePicker().frame(width: 44, height: 44)
                .accessibilityIdentifier("phoneRoutePicker")
        }
    }

    private var inlineControls: some View {
        HStack(spacing: 12) {
            VolumeControlView(player: player, palette: palette)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    adjustments
                    transport
                }
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
        HStack(spacing: AdaptiveBottomPanelMetrics.compactSpacing) {
            IndicatorColumnView(player: player, palette: palette, usesCompactLayout: true)
            VUMeterView(player: player, channel: .left)
            VUMeterView(player: player, channel: .right)
        }
        .frame(height: AdaptiveBottomPanelMetrics.compactMeterHeight)
    }

    private var horizontalVolume: some View {
        HStack(spacing: layout == .classic ? 8 : 6) {
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

import SwiftUI

enum BottomPanelMetrics {
    #if os(iOS)
    static let controlHeight: CGFloat = 44
    static let adjustmentButtonWidth: CGFloat = 44
    static let volumeSlotWidth: CGFloat = 44
    static let volumeStepWidth: CGFloat = 44
    #else
    static let controlHeight: CGFloat = 34
    static let adjustmentButtonWidth: CGFloat = 32
    static let volumeSlotWidth: CGFloat = 17
    static let volumeStepWidth: CGFloat = 24
    #endif
    #if os(iOS)
    static let adjustmentWidth = adjustmentButtonWidth * 3 + 2
    #else
    static let adjustmentWidth: CGFloat = 96
    #endif
    static let volumeHeight: CGFloat = 136

    static func classicColumnWidth(for panelWidth: CGFloat) -> CGFloat {
        max(320, min(panelWidth, panelWidth * 0.5))
    }

    static func classicTransportWidth(for panelWidth: CGFloat) -> CGFloat {
        classicColumnWidth(for: panelWidth) * 2 / 3
    }
}

struct BottomPanelView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let queue: [MediaItem]
    let playItem: (MediaItem) -> Void
    let requestSaveCopy: (MediaItem) -> Void
    var availableWidth: CGFloat?
    @AppStorage(AppSettingsKey.bottomPanelLayout) private var layoutRaw = AppSettingsDefault.bottomPanelLayout
    @Environment(\.usesDividedDisplay) private var usesDividedDisplay

    var body: some View {
        #if os(iOS)
        AdaptiveBottomPanelView(
            player: player,
            selectedItem: selectedItem,
            queue: queue,
            playItem: playItem,
            requestSaveCopy: requestSaveCopy,
            layout: usesDividedDisplay ? .ledHalf : BottomPanelLayout(rawValue: layoutRaw) ?? .ledHalf,
            availableWidth: availableWidth
        )
        #else
        switch BottomPanelLayout(rawValue: layoutRaw) ?? .ledHalf {
        case .classic:
            ClassicBottomPanelView(
                player: player,
                selectedItem: selectedItem,
                queue: queue,
                playItem: playItem,
                requestSaveCopy: requestSaveCopy
            )
        case .ledHalf:
            LEDHalfBottomPanelView(
                player: player,
                selectedItem: selectedItem,
                queue: queue,
                playItem: playItem,
                requestSaveCopy: requestSaveCopy
            )
        }
        #endif
    }
}

private struct ClassicBottomPanelView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let queue: [MediaItem]
    let playItem: (MediaItem) -> Void
    let requestSaveCopy: (MediaItem) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = BottomPanelMetrics.classicColumnWidth(for: proxy.size.width)
            let palette = BottomPanelPalette(colorScheme: colorScheme)
            HStack(alignment: .bottom, spacing: 8) {
                Spacer(minLength: proxy.size.width < 680 ? 0 : 18)
                VStack(spacing: 7) {
                    LEDDisplayView(player: player)
                        .padding(.top, 2)
                        .padding(.horizontal, 1)
                        .padding(.bottom, 1)
                        .background(
                            Rectangle()
                                .fill(palette.displayBezelFill)
                                .overlay(alignment: .top) {
                                    Rectangle()
                                        .fill(palette.displayBezelTopLine)
                                        .frame(height: 1)
                                }
                                .overlay(alignment: .top) {
                                    Rectangle()
                                        .fill(palette.displayBezelInnerShadow)
                                        .frame(height: 3)
                                        .padding(.top, 2)
                                }
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(palette.displayBezelBottomLine)
                                        .frame(height: 1)
                                }
                        )
                    HStack(spacing: 0) {
                        PitchSpeedControlsView(
                            player: player,
                            selectedItem: selectedItem,
                            palette: palette,
                            requestSaveCopy: requestSaveCopy
                        )
                        Spacer(minLength: 16)
                        TransportButtonsView(
                            player: player,
                            selectedItem: selectedItem,
                            queue: queue,
                            palette: palette,
                            playItem: playItem
                        )
                            .frame(width: BottomPanelMetrics.classicTransportWidth(for: proxy.size.width))
                    }
                }
                .frame(width: columnWidth)
                VolumeControlView(player: player, palette: palette)
                    .padding(.bottom, 2)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(palette.panelBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.panelTopStroke).frame(height: 1)
            }
        }
        .frame(height: 170)
    }
}

struct VolumeControlView: View {
    let player: PlayerViewModel
    let palette: BottomPanelPalette
    let height: CGFloat

    private let volumeStep = 0.1

    init(
        player: PlayerViewModel,
        palette: BottomPanelPalette,
        height: CGFloat = BottomPanelMetrics.volumeHeight
    ) {
        self.player = player
        self.palette = palette
        self.height = height
    }

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Text(verbatim: "VOLUME")
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.2)
                .foregroundStyle(palette.labelColor)
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: 12, height: 96)

            VolumeSlotView(value: player.volume, palette: palette) { value in
                player.setVolume(value)
            }
            .frame(width: BottomPanelMetrics.volumeSlotWidth, height: height)

            VStack(spacing: 8) {
                stepButton(identifier: "volumeUpButton", label: "Volume Up", systemName: "plus") {
                    player.setVolume(player.volume + volumeStep)
                }
                .help("Volume Up")
                stepButton(identifier: "volumeDownButton", label: "Volume Down", systemName: "minus") {
                    player.setVolume(player.volume - volumeStep)
                }
                .help("Volume Down")
            }
            .frame(height: height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("volumeControl")
    }

    private func stepButton(
        identifier: String,
        label: LocalizedStringKey,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.normalButtonFill)
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(palette.enabledIcon)
            }
            .frame(width: BottomPanelMetrics.volumeStepWidth)
            .frame(maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(L10n.format("%d percent", Int(player.volume * 100)))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.controlStroke, lineWidth: 1))
        .shadow(color: palette.controlShadow, radius: 1.5, y: 1)
    }
}

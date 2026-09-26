import SwiftUI

enum BottomPanelMetrics {
    static let controlHeight: CGFloat = 34
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
    @AppStorage(AppSettingsKey.bottomPanelLayout) private var layoutRaw = AppSettingsDefault.bottomPanelLayout

    var body: some View {
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
            .frame(width: 17, height: height)

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
            .frame(width: 24)
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

/// BeatJam 風の縦型ボリューム表示: 黒い溝の中に、音量に応じて下から
/// 細い横リブ(セグメント)が積み上がる。クリック/ドラッグで直接指定できる。
private struct VolumeSlotView: View {
    let value: Double
    let palette: BottomPanelPalette
    let onChange: (Double) -> Void

    private let ribHeight: CGFloat = 2
    private let ribSpacing: CGFloat = 1.5
    private let innerPadding: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let innerHeight = proxy.size.height - innerPadding * 2
            let ribCount = max(1, Int((innerHeight + ribSpacing) / (ribHeight + ribSpacing)))
            let filledCount = Int((value * Double(ribCount)).rounded())

            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.volumeSlotFill)

                VStack(spacing: ribSpacing) {
                    ForEach(0..<ribCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(
                                index >= ribCount - filledCount
                                    ? AnyShapeStyle(palette.volumeFilledRib)
                                    : AnyShapeStyle(palette.volumeEmptyRib)
                            )
                            .frame(height: ribHeight)
                    }
                }
                .padding(innerPadding)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(palette.volumeSlotStroke, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.volumeSlotBottomHighlight)
                    .frame(height: 1)
                    .offset(y: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let verticalPosition = min(max(gesture.location.y - innerPadding, 0), innerHeight)
                        onChange(1 - Double(verticalPosition / innerHeight))
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("volumeLevel")
        .accessibilityLabel("Volume")
        .accessibilityValue(L10n.format("%d percent", Int(value * 100)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(value + 0.1)
            case .decrement: onChange(value - 0.1)
            @unknown default: break
            }
        }
        .help("Volume")
    }
}

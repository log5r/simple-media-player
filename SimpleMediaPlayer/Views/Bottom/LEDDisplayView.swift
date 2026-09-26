import SwiftUI

struct LEDDisplayView: View {
    let player: PlayerViewModel
    let height: CGFloat
    let visualizerHeight: CGFloat
    let cornerShape: ConcentricRectangle
    let alignsContentToBottom: Bool
    let informationScale: CGFloat
    let emphasizesTitle: Bool
    let auxiliaryInformationScale: CGFloat
    @AppStorage(AppSettingsKey.ledGlowIntensity) private var ledGlowIntensity = AppSettingsDefault.ledGlowIntensity
    @AppStorage(AppSettingsKey.ledColorHex) private var ledColorHex = AppSettingsDefault.ledColorHex
    @AppStorage(AppSettingsKey.ledBacklitForegroundColorHex)
    private var ledBacklitForegroundColorHex = AppSettingsDefault.ledBacklitForegroundColorHex
    @AppStorage(AppSettingsKey.ledBacklightColorHex)
    private var ledBacklightColorHex = AppSettingsDefault.ledBacklightColorHex
    @AppStorage(AppSettingsKey.ledDisplayStyle) private var ledDisplayStyleRaw = AppSettingsDefault.ledDisplayStyle
    @AppStorage(AppSettingsKey.mediaInfoDisplayStyle)
    private var mediaInfoDisplayStyleRaw = AppSettingsDefault.mediaInfoDisplayStyle
    @AppStorage(AppSettingsKey.ledGlassStyle) private var ledGlassStyleRaw = AppSettingsDefault.ledGlassStyle
    @AppStorage(AppSettingsKey.ledBacklitGlassIntensity)
    private var ledBacklitGlassIntensity = AppSettingsDefault.ledBacklitGlassIntensity

    init(
        player: PlayerViewModel,
        height: CGFloat = 100,
        visualizerHeight: CGFloat = 40,
        cornerShape: ConcentricRectangle = ConcentricRectangle(corners: .fixed(0)),
        alignsContentToBottom: Bool = false,
        informationScale: CGFloat = 1,
        emphasizesTitle: Bool = false,
        auxiliaryInformationScale: CGFloat? = nil
    ) {
        self.player = player
        self.height = height
        self.visualizerHeight = visualizerHeight
        self.cornerShape = cornerShape
        self.alignsContentToBottom = alignsContentToBottom
        self.informationScale = informationScale
        self.emphasizesTitle = emphasizesTitle
        self.auxiliaryInformationScale = auxiliaryInformationScale ?? informationScale
    }

    private var ledDisplayStyle: LEDDisplayStyle {
        palette.style
    }

    private var palette: LEDDisplayPalette {
        LEDDisplayPalette.resolved(
            styleRaw: ledDisplayStyleRaw,
            darkForegroundHex: ledColorHex,
            backlitForegroundHex: ledBacklitForegroundColorHex,
            backlightHex: ledBacklightColorHex,
            backlitGlassIntensity: ledBacklitGlassIntensity
        )
    }

    private var mediaInfoStyle: MediaInfoDisplayStyle {
        MediaInfoDisplayStyle(rawValue: mediaInfoDisplayStyleRaw) ?? .default
    }

    private var glassStyle: LEDGlassStyle {
        LEDGlassStyle(rawValue: ledGlassStyleRaw) ?? .off
    }

    private var titleScale: CGFloat {
        informationScale * (emphasizesTitle ? 1.1 : 1)
    }

    var body: some View {
        let displayShape = cornerShape

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(
                        text: player.currentItem?.title ?? L10n.string("No Track"),
                        font: mediaInfoStyle.titleFont(scale: titleScale, isBold: emphasizesTitle),
                        tracking: mediaInfoStyle.textTracking,
                        color: palette.primaryColor,
                        shadowOpacity: palette.textShadowOpacity,
                        shadowRadius: palette.textShadowRadius
                    )
                        .frame(height: 17 * titleScale)
                    MarqueeText(
                        text: subtitle,
                        font: mediaInfoStyle.subtitleFont(scale: informationScale),
                        tracking: mediaInfoStyle.textTracking,
                        opacity: 0.85,
                        color: palette.primaryColor,
                        shadowOpacity: palette.textShadowOpacity,
                        shadowRadius: palette.textShadowRadius
                    )
                        .frame(height: 15 * informationScale)
                }
                if showsAuxiliaryColumns {
                    AuxiliaryLEDColumns(
                        player: player,
                        palette: palette,
                        informationScale: auxiliaryInformationScale
                    )
                }
                SevenSegmentTimeView(
                    time: player.currentTime,
                    color: palette.primaryColor,
                    scale: informationScale,
                    shadowOpacity: palette.timeShadowOpacity,
                    shadowRadius: palette.timeShadowRadius
                )
            }
            .padding(.bottom, 6)

            if alignsContentToBottom {
                Spacer(minLength: 0)
                MusicAnalysisStripView(player: player, palette: palette, mediaInfoStyle: mediaInfoStyle)
                    .padding(.bottom, 3)
            }

            VisualizerHostView(player: player, palette: palette)
                .frame(height: visualizerHeight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(height: height, alignment: alignsContentToBottom ? .bottom : .center)
        .background(displayBackground(shape: displayShape))
        .clipShape(displayShape)
        // ガラスの映り込みは表示内容より手前に重ねる(コンテンツにも光が乗る)
        .overlay(
            LEDGlassOverlay(style: glassStyle)
                .opacity(palette.glassOverlayOpacity)
                .clipShape(displayShape)
                .allowsHitTesting(false)
        )
    }

    private var subtitle: String {
        guard let item = player.currentItem, item.isVideo == false else { return "" }
        return "\(item.displayArtist) - \(item.displayAlbum)"
    }

    private var showsAuxiliaryColumns: Bool {
        player.currentItem != nil
    }

    private func glowOpacity(_ baseOpacity: Double) -> Double {
        let intensity = min(
            max(ledGlowIntensity, AppSettingsDefault.ledGlowIntensityRange.lowerBound),
            AppSettingsDefault.ledGlowIntensityRange.upperBound
        )
        return min(baseOpacity * intensity, 1)
    }

    @ViewBuilder
    private func displayBackground(shape: ConcentricRectangle) -> some View {
        switch ledDisplayStyle {
        case .dark:
            shape
                .fill(palette.backgroundColor)
                .overlay(
                    shape
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.white.opacity(glowOpacity(0.12)), location: 0.0),
                                    .init(
                                        color: palette.backgroundGlowColor.opacity(glowOpacity(0.08)), location: 0.18
                                    ),
                                    .init(
                                        color: palette.foreground.lowGlowColor.opacity(glowOpacity(0.025)),
                                        location: 0.42
                                    ),
                                    .init(color: .clear, location: 0.64)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)
                )
                .overlay(
                    shape
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.white.opacity(glowOpacity(0.08)), location: 0.0),
                                    .init(color: .clear, location: 0.12)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)
                )
                .overlay(
                    shape
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.black.opacity(0.28), location: 0.0),
                                    .init(color: Color.black.opacity(0.12), location: 0.12),
                                    .init(color: .clear, location: 0.28)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.multiply)
                )
                .overlay(
                    shape
                        .stroke(
                            LinearGradient(
                                colors: [.black.opacity(0.65), .white.opacity(0.32)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2
                        )
                )
        case .backlit:
            shape
                .fill(palette.backgroundColor)
                .overlay(
                    shape
                        .fill(
                            EllipticalGradient(
                                stops: [
                                    .init(color: palette.backgroundGlowColor.opacity(glowOpacity(0.62)), location: 0),
                                    .init(
                                        color: palette.backgroundGlowColor.opacity(glowOpacity(0.32)), location: 0.46
                                    ),
                                    .init(color: .clear, location: 1)
                                ],
                                center: UnitPoint(x: 0.5, y: 0.82),
                                startRadiusFraction: 0,
                                endRadiusFraction: 0.86
                            )
                        )
                )
                .overlay(
                    shape
                        .fill(
                            EllipticalGradient(
                                stops: [
                                    .init(color: .clear, location: 0.56),
                                    .init(color: Color.black.opacity(0.08), location: 0.82),
                                    .init(color: Color.black.opacity(0.18), location: 1)
                                ],
                                center: UnitPoint(x: 0.5, y: 0.68),
                                startRadiusFraction: 0,
                                endRadiusFraction: 1.18
                            )
                        )
                        .blendMode(.multiply)
                )
                .overlay(
                    shape
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.black.opacity(0.12), location: 0),
                                    .init(color: Color.black.opacity(0.04), location: 0.12),
                                    .init(color: .clear, location: 0.32),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.multiply)
                )
                .overlay(
                    shape
                        .stroke(
                            LinearGradient(
                                colors: [.black.opacity(0.72), .black.opacity(0.42)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2
                        )
                )
        }
    }
}

// 時刻表示の左に置く控えめな補助LED表示。
// 2行目は速度/ビットレート、3行目はキー/サンプリング周波数を同一ベースラインに揃える。
private struct AuxiliaryLEDColumns: View {
    let player: PlayerViewModel
    let palette: LEDDisplayPalette
    let informationScale: CGFloat

    var body: some View {
        let rows = player.formatInfo.ledRows

        if rows.count >= 3 {
            compactVideoGrid(rows: rows)
        } else {
            standardGrid(rows: rows)
        }
    }

    private func standardGrid(rows: [LEDInfoRow]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 2, verticalSpacing: 4) {
            if player.currentItem != nil {
                GridRow {
                    stateSymbol
                }
            }

            ForEach(rows) { row in
                GridRow(alignment: .lastTextBaseline) {
                    infoRow(row)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private func compactVideoGrid(rows: [LEDInfoRow]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                stateSymbol
                    .gridCellColumns(2)
                    .gridCellAnchor(.trailing)
            }

            ForEach(0..<2, id: \.self) { rowIndex in
                GridRow(alignment: .lastTextBaseline) {
                    infoRow(rows[rowIndex])
                    if rows.indices.contains(rowIndex + 2) {
                        infoRow(rows[rowIndex + 2])
                    } else {
                        Color.clear
                            .frame(width: 1, height: 1)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private func infoRow(_ row: LEDInfoRow) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            ledNumber(value: row.value, ghost: showsGhostSegments(for: row) ? ghostText(for: row.value) : nil)
            Text(row.unit)
                .font(.custom("Dotrice-Regular", size: 7 * informationScale))
                .foregroundColor(palette.primaryColor.opacity(palette.style == .dark ? 0.34 : 0.76))
        }
    }

    private func ledNumber(value: String, ghost: String?) -> some View {
        ZStack(alignment: .trailing) {
            if let ghost {
                Text(ghost)
                    .foregroundColor(palette.primaryColor.opacity(palette.style == .dark ? 0.10 : 0.12))
            }
            Text(value)
                .foregroundColor(palette.primaryColor.opacity(palette.style == .dark ? 0.58 : 0.82))
        }
        .font(.custom("DSEG7ClassicMini-Regular", size: 8.5 * informationScale))
    }

    private func showsGhostSegments(for row: LEDInfoRow) -> Bool {
        switch row.id {
        case "bitrate", "sampleRate", "totalBitrate":
            false
        default:
            true
        }
    }

    private func ghostText(for value: String) -> String {
        String(value.map { $0.isNumber ? "8" : $0 })
    }

    @ViewBuilder private var stateSymbol: some View {
        let symbolColor = palette.primaryColor.opacity(palette.style == .dark ? 0.68 : 0.84)
        Group {
            if player.isPlaying {
                PlaySymbolShape()
                    .fill(symbolColor)
                    .frame(width: 7, height: 9)
            } else if player.currentTime > 0 {
                HStack(spacing: 2) {
                    Rectangle().fill(symbolColor).frame(width: 2.5, height: 9)
                    Rectangle().fill(symbolColor).frame(width: 2.5, height: 9)
                }
            } else {
                Rectangle()
                    .fill(symbolColor)
                    .frame(width: 7, height: 7)
            }
        }
        // 9ptの再生記号は描画を保ちつつ、親Gridの高さは停止時と同じにする。
        .frame(width: 7, height: 7)
        .shadow(
            color: palette.primaryColor.opacity(palette.symbolShadowOpacity),
            radius: palette.symbolShadowRadius
        )
    }
}

nonisolated private struct PlaySymbolShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

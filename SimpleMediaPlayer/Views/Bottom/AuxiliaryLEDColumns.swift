import SwiftUI

struct AuxiliaryLEDColumns: View {
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
            } else if player.isPaused {
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

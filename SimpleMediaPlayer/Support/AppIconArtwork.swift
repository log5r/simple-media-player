import SwiftUI

/// アプリアイコンの絵柄。1024ptのキャンバスに824ptのタイルを置く macOS の構図で描く。
///
/// 構図はバンドル同梱の `AppIcon.icon`(ガラスの円盤に再生記号を重ねる)にそろえる。
///
/// LED表示と同じ配色をそのまま持ち込めるよう、面と記号の色だけを外から受け取る。
/// アイコン書き出し用のコマンドラインからも単体でコンパイルできるよう、
/// このファイルは SwiftUI 以外に依存しない。
struct AppIconArtwork: View {
    /// sRGB成分。`LEDColorValue` と同じ表現にそろえてある。
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }

        /// 明度だけを落とす。LED面の暗さ(色×0.07)と同じ考え方。
        func scaled(_ factor: Double) -> RGB {
            RGB(
                red: min(red * factor, 1),
                green: min(green * factor, 1),
                blue: min(blue * factor, 1)
            )
        }

        func mixedWithWhite(_ amount: Double) -> RGB {
            let clamped = min(max(amount, 0), 1)
            return RGB(
                red: red + (1 - red) * clamped,
                green: green + (1 - green) * clamped,
                blue: blue + (1 - blue) * clamped
            )
        }
    }

    /// LEDの表示スタイルに対応する2種類の絵柄。
    enum Mode {
        /// 暗い面の上で記号自体が発光する。`LEDDisplayStyle.dark` に対応。
        case luminous
        /// 発光する面に記号が影として落ちる。`LEDDisplayStyle.backlit` に対応。
        case backlit
    }

    /// 面の基準色。luminous ではLED色、backlit ではバックライト色。
    let face: RGB
    /// 再生記号の色。luminous ではLED色、backlit では前景インク色。
    let mark: RGB
    let mode: Mode
    let size: CGFloat

    var body: some View {
        let scale = size / 1024
        let tile = 824 * scale
        let shape = RoundedRectangle(cornerRadius: 185.4 * scale, style: .continuous)

        ZStack {
            Color.clear

            ZStack {
                shape.fill(
                    LinearGradient(
                        colors: faceStops.map(\.color),
                        startPoint: UnitPoint(x: 0.15, y: 0),
                        endPoint: UnitPoint(x: 0.85, y: 1)
                    )
                )

                if mode == .luminous {
                    shape.fill(
                        RadialGradient(
                            colors: [mark.color.opacity(0.34), mark.color.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: tile * 0.5
                        )
                    )
                }

                disc(k: scale)

                playMark(k: scale)

                specular(k: scale)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(mode == .luminous ? 0.26 : 0.38), location: 0),
                                .init(color: .white.opacity(0), location: 0.40)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(shape)

                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            .white.opacity(0.05),
                            .white.opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 6 * scale
                )

                // 明るい面は淡い背景に溶けるため、輪郭を1本入れて輪郭を保つ。
                if mode == .backlit {
                    shape.strokeBorder(face.scaled(0.62).color.opacity(0.55), lineWidth: 3 * scale)
                }
            }
            .frame(width: tile, height: tile)
            .compositingGroup()
            .shadow(color: .black.opacity(0.30), radius: 20 * scale, y: 12 * scale)
        }
        .frame(width: size, height: size)
    }

    private var faceStops: [RGB] {
        switch mode {
        case .luminous:
            // LED面と同じ、色みを残したほぼ黒。中央が LEDColorValue.backgroundColor に一致する。
            [face.scaled(0.13), face.scaled(0.065), face.scaled(0.028)]
        case .backlit:
            [face.mixedWithWhite(0.16), face, face.scaled(0.82)]
        }
    }

    private var markStops: [RGB] {
        switch mode {
        case .luminous:
            [mark.mixedWithWhite(0.38), mark.scaled(0.74)]
        case .backlit:
            [mark.mixedWithWhite(0.22), mark]
        }
    }

    private var markGradient: LinearGradient {
        LinearGradient(
            colors: markStops.map(\.color),
            startPoint: .topLeading,
            endPoint: UnitPoint(x: 0.3, y: 1)
        )
    }

    private var discFill: Color {
        switch mode {
        case .luminous:
            mark.color.opacity(0.12)
        case .backlit:
            .white.opacity(0.45)
        }
    }

    /// 再生記号の下に敷くガラスの円盤。タイルの中央に置く。
    private func disc(k scale: CGFloat) -> some View {
        let circle = Circle()

        return ZStack {
            circle.fill(discFill)
            circle.fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.22), location: 0),
                        .init(color: .white.opacity(0), location: 0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            circle.strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(0.50),
                        .white.opacity(0.06),
                        .white.opacity(0.20)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 4 * scale
            )
        }
        .frame(width: 548 * scale, height: 548 * scale)
        .shadow(
            color: .black.opacity(mode == .luminous ? 0.35 : 0.16),
            radius: 18 * scale,
            y: 10 * scale
        )
    }

    @ViewBuilder
    private func playMark(k scale: CGFloat) -> some View {
        let path = markPath(k: scale)
        let stroke = StrokeStyle(lineWidth: 40 * scale, lineJoin: .round)

        ZStack {
            if mode == .luminous {
                ZStack {
                    path.fill(mark.color)
                    path.stroke(mark.color, style: stroke)
                }
                .blur(radius: 18 * scale)
                .opacity(0.38)
            }

            ZStack {
                path.fill(markGradient)
                path.stroke(markGradient, style: stroke)
            }
            .shadow(
                color: .black.opacity(mode == .backlit ? 0.18 : 0),
                radius: 9 * scale,
                y: 5 * scale
            )
        }
    }

    /// タイル内の座標(824基準)で描く再生記号。角はストロークの丸結合で落とす。
    private func markPath(k scale: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 344 * scale, y: 299 * scale))
            path.addLine(to: CGPoint(x: 548 * scale, y: 412 * scale))
            path.addLine(to: CGPoint(x: 344 * scale, y: 525 * scale))
            path.closeSubpath()
        }
    }

    /// ガラス面の映り込み。上辺から緩く垂れ下がる帯。
    private func specular(k scale: CGFloat) -> Path {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 824 * scale, y: 0))
            path.addLine(to: CGPoint(x: 824 * scale, y: 300 * scale))
            path.addCurve(
                to: CGPoint(x: 0, y: 440 * scale),
                control1: CGPoint(x: 620 * scale, y: 396 * scale),
                control2: CGPoint(x: 210 * scale, y: 352 * scale)
            )
            path.closeSubpath()
        }
    }
}

import SwiftUI

// LED表示部に被せる「湾曲ガラス」の映り込み表現。
// コンテンツより手前に overlay で重ねる前提で、.screen(反射光)と
// .multiply(曲率による陰り)のグラデーションだけで構成する。
// crtBulge/bevel の白ハイライトはテキスト可読性のため最大 0.30 に抑える。
// cylindrical は BeatJam 実機の実測再現を優先し、上端のみ例外的に強い
// (文字行にかかる帯が濃いのは意図通り)。
// 呼び出し側で allowsHitTesting(false) を付けること。
struct LEDGlassOverlay: View {
    let style: LEDGlassStyle

    var body: some View {
        switch style {
        case .off:
            EmptyView()
        case .cylindrical:
            CylindricalGlass()
        case .crtBulge:
            CRTBulgeGlass()
        case .bevel:
            BevelGlass()
        }
    }
}

// 横に寝かせた円筒ガラス。BeatJam の LED 部 (tmp/BeatJam-LEDUI.png) の
// 行別実測プロファイルの再現: 純白・水平一様のウォッシュが上端 0.72 から
// 高さ 46% でゼロに減衰(最初の 5% だけ急落、その後ほぼ直線)。
// 暗帯は無く、下端は最下行の細いリムライトのみ
private struct CylindricalGlass: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.72), location: 0.0),
                .init(color: .white.opacity(0.60), location: 0.02),
                .init(color: .white.opacity(0.53), location: 0.05),
                .init(color: .white.opacity(0.46), location: 0.10),
                .init(color: .white.opacity(0.34), location: 0.17),
                .init(color: .white.opacity(0.26), location: 0.24),
                .init(color: .white.opacity(0.17), location: 0.31),
                .init(color: .white.opacity(0.10), location: 0.38),
                .init(color: .clear, location: 0.46),
                .init(color: .clear, location: 0.965),
                .init(color: .white.opacity(0.16), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .blendMode(.screen)
    }
}

// ブラウン管風に中央が膨らんだガラス。左上の広い光だまり＋スペキュラの芯、
// 四隅は曲率で暗く落とすヴィネット
private struct CRTBulgeGlass: View {
    var body: some View {
        ZStack {
            EllipticalGradient(
                stops: [
                    .init(color: .white.opacity(0.20), location: 0.0),
                    .init(color: .white.opacity(0.07), location: 0.42),
                    .init(color: .clear, location: 0.62)
                ],
                center: UnitPoint(x: 0.30, y: -0.25),
                startRadiusFraction: 0,
                endRadiusFraction: 1.0
            )
            .blendMode(.screen)

            EllipticalGradient(
                stops: [
                    .init(color: .white.opacity(0.30), location: 0.0),
                    .init(color: .clear, location: 1.0)
                ],
                center: UnitPoint(x: 0.22, y: 0.10),
                startRadiusFraction: 0,
                endRadiusFraction: 0.16
            )
            .blendMode(.screen)

            EllipticalGradient(
                stops: [
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.10), location: 0.78),
                    .init(color: .black.opacity(0.30), location: 1.0)
                ],
                center: UnitPoint(x: 0.5, y: 0.48),
                startRadiusFraction: 0,
                endRadiusFraction: 1.35
            )
            .blendMode(.multiply)
        }
    }
}

// 厚いガラス板。面はほぼ素通しのまま、縁のリム反射・フレネル・
// わずかな青緑の色味と右下の沈み込みで厚みを表現する。
// リムの blur が枠外へにじむため clipped で切る
private struct BevelGlass: View {
    private let fresnelColor = Color(red: 0.86, green: 0.96, blue: 0.88)

    var body: some View {
        ZStack {
            Color(red: 0.63, green: 0.75, blue: 0.67).opacity(0.05)

            EllipticalGradient(
                stops: [
                    .init(color: .clear, location: 0.62),
                    .init(color: fresnelColor.opacity(0.07), location: 0.88),
                    .init(color: fresnelColor.opacity(0.12), location: 1.0)
                ],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 1.1
            )
            .blendMode(.screen)

            EllipticalGradient(
                stops: [
                    .init(color: .white.opacity(0.25), location: 0.0),
                    .init(color: .clear, location: 1.0)
                ],
                center: UnitPoint(x: 0.05, y: 0.08),
                startRadiusFraction: 0,
                endRadiusFraction: 0.18
            )
            .blendMode(.screen)

            Rectangle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.30), .white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
                .blur(radius: 1.5)
                .blendMode(.screen)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.90),
                    .init(color: .black.opacity(0.18), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.multiply)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.94),
                    .init(color: .black.opacity(0.14), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .blendMode(.multiply)
        }
        .clipped()
    }
}

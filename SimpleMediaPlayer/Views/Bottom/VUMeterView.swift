import SwiftUI

/// アナログ VU メーター 1 基。筐体の開口に面一で埋め込まれたガラスの奥に
/// 文字盤があり、その手前で針が振れる構造を Canvas で描く。
/// 静的レイヤー(開口・側壁・文字盤・照明・目盛・影・ガラス)と、
/// 毎フレーム描き直す針レイヤーを別ビューに分け、針以外は再描画しない。
struct VUMeterView: View {
    enum Channel {
        case left
        case right

        var label: String {
            switch self {
            case .left: "L"
            case .right: "R"
            }
        }
    }

    let player: PlayerViewModel
    let channel: Channel

    @AppStorage(AppSettingsKey.vuMeterFaceColorHex) private var faceHex = AppSettingsDefault.vuMeterFaceColorHex
    @AppStorage(AppSettingsKey.vuMeterLampColorHex) private var lampHex = AppSettingsDefault.vuMeterLampColorHex
    @AppStorage(AppSettingsKey.vuMeterShadowOpacity) private var shadowOpacity = AppSettingsDefault.vuMeterShadowOpacity
    @AppStorage(AppSettingsKey.vuMeterShadowExtent) private var shadowExtent = AppSettingsDefault.vuMeterShadowExtent

    var body: some View {
        let palette = VUMeterPalette.resolved(
            faceHex: faceHex, lampHex: lampHex,
            shadowOpacity: shadowOpacity, shadowExtent: shadowExtent
        )

        GeometryReader { proxy in
            let geometry = VUMeterGeometry(size: proxy.size)
            ZStack {
                VUMeterFaceLayer(palette: palette, geometry: geometry, channelLabel: channel.label)
                VUMeterNeedleLayer(player: player, channel: channel, palette: palette, geometry: geometry)
                VUMeterGlassLayer(palette: palette, geometry: geometry)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Level meter"))
        .accessibilityValue(Text(verbatim: channel.label))
    }
}

/// 設計空間 211×96 を実サイズに等倍スケーリングして中央配置するための変換。
nonisolated struct VUMeterGeometry: Equatable {
    static let designSize = CGSize(width: 211, height: 96)
    static let pivot = CGPoint(x: 105.5, y: 128)
    static let arcRadius: CGFloat = 104
    static let inset: CGFloat = 2.5      // 開口の縁から文字盤まで(側壁 2pt + 隙間線)
    static let wallStart: CGFloat = 0.5
    /// この幅(pt)未満では数値ラベルを描かない
    static let labelMinimumWidth: CGFloat = 130

    let size: CGSize
    let scale: CGFloat
    let origin: CGPoint

    init(size: CGSize) {
        self.size = size
        let scale = min(size.width / Self.designSize.width, size.height / Self.designSize.height)
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        origin = CGPoint(
            x: (size.width - Self.designSize.width * self.scale) / 2,
            y: (size.height - Self.designSize.height * self.scale) / 2
        )
    }

    var showsLabels: Bool {
        Self.designSize.width * scale >= Self.labelMinimumWidth
    }

    var faceRect: CGRect {
        CGRect(origin: .zero, size: Self.designSize).insetBy(dx: Self.inset, dy: Self.inset)
    }

    func apply(to context: inout GraphicsContext) {
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
    }

    /// 針位置 position(0…1)から弧上の点を返す
    static func arcPoint(t position: CGFloat, radius: CGFloat) -> CGPoint {
        let angle = CGFloat(VUMeterScale.angleDegrees(for: Float(position))) * .pi / 180
        return CGPoint(x: pivot.x + sin(angle) * radius, y: pivot.y - cos(angle) * radius)
    }
}

// MARK: - Static face

private struct VUMeterFaceLayer: View {
    let palette: VUMeterPalette
    let geometry: VUMeterGeometry
    let channelLabel: String

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            geometry.apply(to: &context)
            let design = CGRect(origin: .zero, size: VUMeterGeometry.designSize)
            let face = geometry.faceRect

            drawOpening(in: &context, design: design, face: face)

            var faceContext = context
            faceContext.clip(to: Path(roundedRect: face, cornerRadius: 1.5))
            drawFace(in: &faceContext, face: face)
            drawScale(in: &faceContext)
            drawWellShadow(in: &faceContext, face: face)
        }
    }

    private func drawOpening(in context: inout GraphicsContext, design: CGRect, face: CGRect) {
        let wallStart = VUMeterGeometry.wallStart
        let inset = VUMeterGeometry.inset
        let width = design.width
        let height = design.height

        // 側壁(筐体材質)。上壁が最も暗く、下壁が受光する
        func wall(_ points: [CGPoint], _ hex: String) {
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            context.fill(path, with: .color(LEDColorValue.resolved(hex).color))
        }
        wall([
            CGPoint(x: wallStart, y: wallStart), CGPoint(x: width - wallStart, y: wallStart),
            CGPoint(x: width - inset, y: inset), CGPoint(x: inset, y: inset)
        ], "#050607")
        wall([
            CGPoint(x: wallStart, y: height - wallStart), CGPoint(x: width - wallStart, y: height - wallStart),
            CGPoint(x: width - inset, y: height - inset), CGPoint(x: inset, y: height - inset)
        ], "#3A3D44")
        wall([
            CGPoint(x: wallStart, y: wallStart), CGPoint(x: inset, y: inset),
            CGPoint(x: inset, y: height - inset), CGPoint(x: wallStart, y: height - wallStart)
        ], "#14161A")
        wall([
            CGPoint(x: width - wallStart, y: wallStart), CGPoint(x: width - inset, y: inset),
            CGPoint(x: width - inset, y: height - inset), CGPoint(x: width - wallStart, y: height - wallStart)
        ], "#1C1F24")

        // ガラスと筐体の隙間線、下縁の受光
        context.stroke(
            Path(roundedRect: design.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2),
            with: .color(.black.opacity(0.85)),
            lineWidth: 1
        )
        var lip = Path()
        lip.move(to: CGPoint(x: 1, y: height - 0.5))
        lip.addLine(to: CGPoint(x: width - 1, y: height - 0.5))
        context.stroke(lip, with: .color(.white.opacity(0.10)), lineWidth: 1)
    }

    private func drawFace(in context: inout GraphicsContext, face: CGRect) {
        let width = VUMeterGeometry.designSize.width
        let height = VUMeterGeometry.designSize.height
        let fill = Path(face)

        context.fill(fill, with: .color(palette.faceColor))

        if palette.isDarkFace {
            context.fill(
                fill,
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.13), location: 0),
                        .init(color: .white.opacity(0.05), location: 0.6),
                        .init(color: .white.opacity(0), location: 1)
                    ]),
                    center: CGPoint(x: width * 0.66, y: height * 0.6),
                    startRadius: 0,
                    endRadius: width * 0.62
                )
            )
        }

        // ランプ照明(下辺中央)
        let lamp = palette.lampColor
        let intensity = palette.lampIntensity
        context.fill(
            fill,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: lamp.opacity(intensity), location: 0),
                    .init(color: lamp.opacity(intensity * 0.33), location: 0.55),
                    .init(color: lamp.opacity(0), location: 1)
                ]),
                center: CGPoint(x: width / 2, y: height - 4),
                startRadius: 0,
                endRadius: width * 0.62
            )
        )

        // 四隅のビネット
        context.fill(
            fill,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0), location: 0.55),
                    .init(color: .black.opacity(palette.isDarkFace ? 0.5 : 0.28), location: 1)
                ]),
                center: CGPoint(x: width / 2, y: height * 0.55),
                startRadius: 0,
                endRadius: width * 0.62
            )
        )
    }

    private func drawScale(in context: inout GraphicsContext) {
        var scale = context
        scale.opacity = 0.92
        let radius = VUMeterGeometry.arcRadius
        let ticks = VUMeterScale.ticks
        let zero = CGFloat(ticks.first(where: { $0.vu == 0 })?.t ?? 0.78)

        scale.stroke(arc(from: 0, to: zero, radius: radius), with: .color(palette.ink), lineWidth: 1.6)
        scale.stroke(arc(from: zero, to: 1, radius: radius), with: .color(palette.red), lineWidth: 3.2)

        for tick in ticks {
            let position = CGFloat(tick.t)
            let color = position >= zero ? palette.red : palette.ink
            var mark = Path()
            mark.move(to: VUMeterGeometry.arcPoint(t: position, radius: radius))
            mark.addLine(to: VUMeterGeometry.arcPoint(t: position, radius: radius - 7))
            scale.stroke(mark, with: .color(color), lineWidth: 1.4)

            if geometry.showsLabels {
                let label = Text(verbatim: tickLabel(tick.vu))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(color)
                scale.draw(
                    scale.resolve(label),
                    at: VUMeterGeometry.arcPoint(t: position, radius: radius + 9), anchor: .center
                )
            }
        }

        for index in 0...20 {
            let position = CGFloat(index) / 20
            if ticks.contains(where: { abs(CGFloat($0.t) - position) < 0.02 }) { continue }
            var mark = Path()
            mark.move(to: VUMeterGeometry.arcPoint(t: position, radius: radius))
            mark.addLine(to: VUMeterGeometry.arcPoint(t: position, radius: radius - 3.5))
            scale.stroke(mark, with: .color(palette.ink.opacity(0.7)), lineWidth: 0.8)
        }

        let width = VUMeterGeometry.designSize.width
        let height = VUMeterGeometry.designSize.height
        let title = Text(verbatim: "VU")
            .font(.system(size: 15, weight: .semibold)).kerning(2).foregroundStyle(palette.ink)
        scale.draw(scale.resolve(title), at: CGPoint(x: width / 2, y: height - 19), anchor: .center)
        let channel = Text(verbatim: channelLabel)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.ink)
        scale.draw(
            scale.resolve(channel),
            at: CGPoint(x: channelLabel == "L" ? 18 : width - 18, y: height - 11), anchor: .center
        )
    }

    private func drawWellShadow(in context: inout GraphicsContext, face: CGRect) {
        let shadow = palette.wellShadow
        let fill = Path(face)

        context.fill(
            fill,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(shadow.top.startOpacity), location: 0),
                    .init(color: .black.opacity(shadow.top.midOpacity), location: shadow.top.midStop),
                    .init(color: .black.opacity(0), location: shadow.top.endStop)
                ]),
                startPoint: CGPoint(x: face.midX, y: face.minY),
                endPoint: CGPoint(x: face.midX, y: face.maxY)
            )
        )
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(shadow.left.opacity), location: 0),
                    .init(color: .black.opacity(0), location: shadow.left.widthFraction),
                    .init(color: .black.opacity(0), location: 1 - shadow.right.widthFraction),
                    .init(color: .black.opacity(shadow.right.opacity), location: 1)
                ]),
                startPoint: CGPoint(x: face.minX, y: face.midY),
                endPoint: CGPoint(x: face.maxX, y: face.midY)
            )
        )
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(shadow.bottom.opacity), location: 0),
                    .init(color: .black.opacity(0), location: shadow.bottom.widthFraction)
                ]),
                startPoint: CGPoint(x: face.midX, y: face.maxY),
                endPoint: CGPoint(x: face.midX, y: face.minY)
            )
        )

        guard let contact = shadow.contact else { return }
        let gradientStops = { (stops: [WellShadow.ContactShadow.Stop]) in
            stops.map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) }
        }
        // 暗い文字盤: 左壁直近の硬い接触影と左上コーナーの放射影
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(stops: gradientStops(contact.linear)),
                startPoint: CGPoint(x: 0, y: face.midY),
                endPoint: CGPoint(x: VUMeterGeometry.designSize.width, y: face.midY)
            )
        )
        context.fill(
            fill,
            with: .radialGradient(
                Gradient(stops: gradientStops(contact.corner)),
                center: CGPoint(x: face.minX, y: face.minY),
                startRadius: 0,
                endRadius: VUMeterGeometry.designSize.width * contact.cornerRadiusFraction
            )
        )
    }

    private func arc(from startPosition: CGFloat, to endPosition: CGFloat, radius: CGFloat) -> Path {
        var path = Path()
        let start = CGFloat(VUMeterScale.angleDegrees(for: Float(startPosition)))
        let end = CGFloat(VUMeterScale.angleDegrees(for: Float(endPosition)))
        path.addArc(
            center: VUMeterGeometry.pivot,
            radius: radius,
            startAngle: .degrees(Double(start) - 90),
            endAngle: .degrees(Double(end) - 90),
            clockwise: false
        )
        return path
    }

    private func tickLabel(_ volumeUnits: Float) -> String {
        let value = Int(volumeUnits.rounded())
        return value > 0 ? "+\(value)" : "\(value)"
    }
}

// MARK: - Needle (per frame)

private struct VUMeterNeedleLayer: View {
    let player: PlayerViewModel
    let channel: VUMeterView.Channel
    let palette: VUMeterPalette
    let geometry: VUMeterGeometry

    @AppStorage(AppSettingsKey.visualizerResponseMode)
    private var responseModeRaw = AppSettingsDefault.visualizerResponseMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = NeedleModel()
    @State private var isSettling = false

    var body: some View {
        let responseMode = VisualizerResponseMode(rawValue: responseModeRaw) ?? .normal

        if reduceMotion {
            Canvas(rendersAsynchronously: false) { context, _ in
                draw(position: 0, in: &context)
            }
        } else {
            TimelineView(.animation(
                minimumInterval: 1.0 / responseMode.framesPerSecond,
                paused: player.isPlaying == false && isSettling == false
            )) { timeline in
                Canvas(rendersAsynchronously: false) { context, _ in
                    let position = model.advance(to: timeline.date, frame: player.audioFrame, channel: channel)
                    draw(position: CGFloat(position), in: &context)
                }
            }
            .modifier(VisualizationConsumer(player: player))
            .task(id: player.isPlaying) {
                guard player.isPlaying == false, model.isMoving else {
                    isSettling = false
                    return
                }
                isSettling = true
                do {
                    try await Task.sleep(for: .seconds(VUMeterScale.settlingDuration))
                    try Task.checkCancellation()
                    guard player.isPlaying == false else { return }
                    model.reset()
                    isSettling = false
                } catch {}
            }
        }
    }

    private func draw(position: CGFloat, in context: inout GraphicsContext) {
        geometry.apply(to: &context)
        context.clip(to: Path(roundedRect: geometry.faceRect, cornerRadius: 1.5))

        let angle = CGFloat(VUMeterScale.angleDegrees(for: Float(position)))
        let pivot = VUMeterGeometry.pivot
        let tip = VUMeterGeometry.arcRadius + 4
        var needle = Path()
        needle.move(to: CGPoint(x: pivot.x - 1.1, y: pivot.y))
        needle.addLine(to: CGPoint(x: pivot.x - 0.3, y: pivot.y - tip))
        needle.addLine(to: CGPoint(x: pivot.x + 0.3, y: pivot.y - tip))
        needle.addLine(to: CGPoint(x: pivot.x + 1.1, y: pivot.y))
        needle.closeSubpath()

        let rotation = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: angle * .pi / 180)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        let rotated = needle.applying(rotation)

        // 針は文字盤から浮いているので、右下に落ちる影を先に描く
        var shadow = context
        shadow.translateBy(x: 2, y: 3.5)
        shadow.addFilter(.blur(radius: 1.8))
        shadow.fill(rotated, with: .color(.black.opacity(0.44)))

        context.fill(rotated, with: .color(palette.needle))
    }

    /// 針のバリスティクス状態。描画クロージャ内から更新するため参照型にする
    @MainActor
    private final class NeedleModel {
        private var ballistics = VUMeterScale.Ballistics()
        private var lastDate: Date?

        var isMoving: Bool {
            abs(ballistics.position) > 0.001 || abs(ballistics.velocity) > 0.001
        }

        func reset() {
            ballistics = VUMeterScale.Ballistics()
            lastDate = nil
        }

        func advance(to date: Date, frame: AudioFrameData, channel: VUMeterView.Channel) -> Float {
            let rms = channel == .left ? frame.rmsL : frame.rmsR
            let target = frame.isPlaying ? VUMeterScale.needlePosition(normalizedRMS: rms) : 0
            let elapsedTime = Float(lastDate.map { date.timeIntervalSince($0) } ?? 1.0 / 30)
            lastDate = date
            ballistics.step(toward: target, dt: elapsedTime)
            return min(1, max(0, ballistics.position))
        }
    }
}

// MARK: - Glass (static, on top)

private struct VUMeterGlassLayer: View {
    let palette: VUMeterPalette
    let geometry: VUMeterGeometry

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            geometry.apply(to: &context)
            let width = VUMeterGeometry.designSize.width
            let height = VUMeterGeometry.designSize.height
            let glass = CGRect(x: 1, y: 1, width: width - 2, height: height - 2)
            context.clip(to: Path(roundedRect: glass, cornerRadius: 1.5))
            let fill = Path(glass)
            let glassIntensity = palette.glassIntensity

            // 淡い全面ハイライトと下辺の二次反射
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.14), location: 0),
                        .init(color: .white.opacity(0.09), location: 0.28),
                        .init(color: .white.opacity(0), location: 0.45)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: width, y: height)
                )
            )
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.05), location: 0),
                        .init(color: .white.opacity(0), location: 0.3)
                    ]),
                    startPoint: CGPoint(x: width / 2, y: height),
                    endPoint: CGPoint(x: width / 2, y: 0)
                )
            )

            // −24° の斜め反射帯(内側の縁が硬い)と平行する細い二次帯
            let center = CGPoint(x: width / 2, y: height / 2)
            let theta = -24 * CGFloat.pi / 180
            let half = CGPoint(x: cos(theta) * width / 2, y: sin(theta) * width / 2)
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0), location: 0.22),
                        .init(color: .white.opacity(0.17 * glassIntensity), location: 0.30),
                        .init(color: .white.opacity(0.20 * glassIntensity), location: 0.44),
                        .init(color: .white.opacity(0.05 * glassIntensity), location: 0.47),
                        .init(color: .white.opacity(0), location: 0.52),
                        .init(color: .white.opacity(0.08 * glassIntensity), location: 0.58),
                        .init(color: .white.opacity(0.09 * glassIntensity), location: 0.63),
                        .init(color: .white.opacity(0), location: 0.66)
                    ]),
                    startPoint: CGPoint(x: center.x - half.x, y: center.y - half.y),
                    endPoint: CGPoint(x: center.x + half.x, y: center.y + half.y)
                )
            )

            // 左上の窓/ランプの湾曲反射
            context.fill(
                fill,
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0), location: 0.84),
                        .init(color: .white.opacity(0.14 * glassIntensity), location: 0.90),
                        .init(color: .white.opacity(0.10 * glassIntensity), location: 0.96),
                        .init(color: .white.opacity(0), location: 1)
                    ]),
                    center: CGPoint(x: width * 0.18, y: -height * 0.9),
                    startRadius: 0,
                    endRadius: height * 1.75
                )
            )

            // ガラス板の切断面が光を受ける上端・左端
            var top = Path()
            top.move(to: CGPoint(x: 1.5, y: 1.5))
            top.addLine(to: CGPoint(x: width - 1.5, y: 1.5))
            context.stroke(top, with: .color(.white.opacity(0.28 * glassIntensity)), lineWidth: 1)
            var left = Path()
            left.move(to: CGPoint(x: 1.5, y: 1.5))
            left.addLine(to: CGPoint(x: 1.5, y: height - 1.5))
            context.stroke(left, with: .color(.white.opacity(0.14 * glassIntensity)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

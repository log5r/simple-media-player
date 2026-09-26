import SwiftUI

struct LEDStyle {
    var onColor = Color(red: 0.72, green: 0.91, blue: 0.53)
    var peakColor = Color(red: 0.9, green: 1.0, blue: 0.75)
    var offOpacity = 0.08
    var glowOpacity = 0.8

    init() {}

    init(palette: LEDDisplayPalette) {
        onColor = palette.visualizerOnColor
        peakColor = palette.visualizerPeakColor
        offOpacity = palette.visualizerOffOpacity
    }
}

@MainActor
protocol LEDVisualizer: Identifiable {
    var id: String { get }
    var displayName: LocalizedStringKey { get }
    var requiredBandCount: Int? { get }
    func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        frame: AudioFrameData,
        style: LEDStyle,
        spectrumFrameRate: Int,
        isEqualizerActive: Bool
    )
}

@MainActor
struct VisualizerRegistry {
    static let shared = VisualizerRegistry()
    let visualizers: [any LEDVisualizer] = [
        SpectrumVisualizer()
    ]

    func visualizer(for id: String) -> any LEDVisualizer {
        visualizers.first(where: { $0.id == id }) ?? visualizers[0]
    }

    func next(after id: String) -> any LEDVisualizer {
        guard let index = visualizers.firstIndex(where: { $0.id == id }) else { return visualizers[0] }
        return visualizers[(index + 1) % visualizers.count]
    }
}

struct SpectrumVisualizer: @MainActor LEDVisualizer {
    let id = "spectrum.stereo"
    let displayName: LocalizedStringKey = "Stereo Spectrum"
    let requiredBandCount: Int? = 16

    func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        frame: AudioFrameData,
        style: LEDStyle,
        spectrumFrameRate: Int,
        isEqualizerActive: Bool
    ) {
        let gap: CGFloat = 38
        let channelWidth = max(1, (size.width - gap) / 2)
        drawChannel(
            levels: frame.bandsL,
            peaks: frame.peaksL,
            x: 0,
            width: channelWidth,
            height: size.height,
            mirrored: true,
            context: &context,
            style: style
        )
        drawChannel(
            levels: frame.bandsR,
            peaks: frame.peaksR,
            x: channelWidth + gap,
            width: channelWidth,
            height: size.height,
            mirrored: false,
            context: &context,
            style: style
        )

        let labelFont = Font.system(size: 9, weight: .bold, design: .monospaced)
        let leftLabel = Text("L")
            .font(labelFont)
            .foregroundStyle(style.onColor)
        let rightLabel = Text("R")
            .font(labelFont)
            .foregroundStyle(style.onColor)
        let defaultLabelY: CGFloat = min(size.height - 8, max(8, size.height * 0.38))
        let equalizerRect = isEqualizerActive ? equalizerIndicatorRect(
            size: size,
            channelWidth: channelWidth,
            gap: gap
        ) : nil
        let defaultFrameRateY = min(size.height - 6, defaultLabelY + 11)
        let frameRateY = equalizerRect.map { min(defaultFrameRateY, $0.minY - 6) } ?? defaultFrameRateY
        let labelY = equalizerRect.map { _ in min(defaultLabelY, frameRateY - 9) } ?? defaultLabelY
        context.draw(leftLabel, at: CGPoint(x: channelWidth + gap * 0.32, y: labelY), anchor: .center)
        context.draw(rightLabel, at: CGPoint(x: channelWidth + gap * 0.68, y: labelY), anchor: .center)

        let frameRateValue = formatFrameRate(spectrumFrameRate)
        let frameRateFont = Font.custom("DSEG7ClassicMini-Regular", size: 7.5)
        context.draw(
            Text(ghostText(for: frameRateValue))
                .font(frameRateFont)
                .foregroundStyle(style.onColor.opacity(0.08)),
            at: CGPoint(x: channelWidth + gap * 0.5, y: frameRateY),
            anchor: .center
        )
        context.draw(
            Text(frameRateValue)
                .font(frameRateFont)
                .foregroundStyle(style.onColor.opacity(0.62)),
            at: CGPoint(x: channelWidth + gap * 0.5, y: frameRateY),
            anchor: .center
        )

        if let equalizerRect {
            var border = Path()
            border.addRect(equalizerRect)
            context.stroke(
                border,
                with: .color(style.onColor.opacity(0.78)),
                style: StrokeStyle(lineWidth: 1.25)
            )
            context.draw(
                Text(verbatim: "EQ")
                    .font(.custom("Dotrice-Regular", size: min(12, max(10, equalizerRect.height * 0.68))))
                    .foregroundStyle(style.onColor.opacity(0.88)),
                at: CGPoint(x: equalizerRect.midX, y: equalizerRect.midY),
                anchor: .center
            )
        }
    }

    private func equalizerIndicatorRect(size: CGSize, channelWidth: CGFloat, gap: CGFloat) -> CGRect {
        let height = min(17, max(14, size.height * 0.30))
        let width = min(25, gap - 13)
        return CGRect(
            x: channelWidth + (gap - width) / 2,
            y: size.height - height - 0.625,
            width: width,
            height: height
        )
    }

    private func formatFrameRate(_ frameRate: Int) -> String {
        let clampedFrameRate = min(999, max(0, frameRate))
        return clampedFrameRate < 100 ? String(format: "%02d", clampedFrameRate) : String(clampedFrameRate)
    }

    private func ghostText(for text: String) -> String {
        String(text.map { $0.isNumber ? "8" : $0 })
    }

    private func drawChannel(
        levels: [Float],
        peaks: [Float],
        x horizontalOrigin: CGFloat,
        width: CGFloat,
        height: CGFloat,
        mirrored: Bool,
        context: inout GraphicsContext,
        style: LEDStyle
    ) {
        let bandCount = max(1, levels.count)
        let segmentCount = 12
        let gapX: CGFloat = 3
        let gapY: CGFloat = 2
        let bandWidth = max(2, (width - gapX * CGFloat(bandCount - 1)) / CGFloat(bandCount))
        let segmentHeight = max(1.5, (height - gapY * CGFloat(segmentCount - 1)) / CGFloat(segmentCount))
        var onPath = Path()
        var peakPath = Path()
        var offPath = Path()

        for band in 0..<bandCount {
            let sourceIndex = mirrored ? bandCount - band - 1 : band
            let level = CGFloat(levels.indices.contains(sourceIndex) ? levels[sourceIndex] : 0)
            let peak = CGFloat(peaks.indices.contains(sourceIndex) ? peaks[sourceIndex] : 0)
            let onSegments = Int((level * CGFloat(segmentCount)).rounded())
            let peakSegment = Int((peak * CGFloat(segmentCount)).rounded())

            for segment in 0..<segmentCount {
                let rect = CGRect(
                    x: horizontalOrigin + CGFloat(band) * (bandWidth + gapX),
                    y: height - CGFloat(segment + 1) * segmentHeight - CGFloat(segment) * gapY,
                    width: bandWidth,
                    height: segmentHeight
                )
                let path = Path(roundedRect: rect, cornerRadius: 1.2)
                if segment < onSegments {
                    onPath.addPath(path)
                } else if segment == peakSegment - 1 && peakSegment > 0 {
                    peakPath.addPath(path)
                } else {
                    offPath.addPath(path)
                }
            }
        }

        context.fill(offPath, with: .color(style.onColor.opacity(style.offOpacity)))
        context.fill(onPath, with: .color(style.onColor))
        context.fill(peakPath, with: .color(style.peakColor))
    }
}

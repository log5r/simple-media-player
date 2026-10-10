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
    /// Shared by every host, since the registry holds a single instance.
    let cache = SpectrumVisualizerCache()
    static let segmentCount = 12

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

        let labels = cache.labels(color: style.onColor, frameRate: spectrumFrameRate)
        let defaultLabelY: CGFloat = min(size.height - 8, max(8, size.height * 0.38))
        let equalizerRect = isEqualizerActive ? equalizerIndicatorRect(
            size: size,
            channelWidth: channelWidth,
            gap: gap
        ) : nil
        let defaultFrameRateY = min(size.height - 6, defaultLabelY + 11)
        let frameRateY = equalizerRect.map { min(defaultFrameRateY, $0.minY - 6) } ?? defaultFrameRateY
        let labelY = equalizerRect.map { _ in min(defaultLabelY, frameRateY - 9) } ?? defaultLabelY
        context.draw(labels.left, at: CGPoint(x: channelWidth + gap * 0.32, y: labelY), anchor: .center)
        context.draw(labels.right, at: CGPoint(x: channelWidth + gap * 0.68, y: labelY), anchor: .center)

        let frameRatePoint = CGPoint(x: channelWidth + gap * 0.5, y: frameRateY)
        context.draw(labels.frameRateGhost, at: frameRatePoint, anchor: .center)
        context.draw(labels.frameRate, at: frameRatePoint, anchor: .center)

        if let equalizerRect {
            drawEqualizerIndicator(in: equalizerRect, context: &context, style: style)
        }
    }

    private func drawEqualizerIndicator(in rect: CGRect, context: inout GraphicsContext, style: LEDStyle) {
        var border = Path()
        border.addRect(rect)
        context.stroke(
            border,
            with: .color(style.onColor.opacity(0.78)),
            style: StrokeStyle(lineWidth: 1.25)
        )
        context.draw(
            Text(verbatim: "EQ")
                .font(cache.equalizerFont(size: min(12, max(10, rect.height * 0.68))))
                .foregroundStyle(style.onColor.opacity(0.88)),
            at: CGPoint(x: rect.midX, y: rect.midY),
            anchor: .center
        )
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
        let segmentCount = Self.segmentCount
        let segments = cache.segments(for: SpectrumSegmentLayout(
            origin: horizontalOrigin, width: width, height: height, bandCount: bandCount
        ))
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
                let path = segments[band * segmentCount + segment]
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

struct SpectrumSegmentLayout: Hashable {
    var origin: CGFloat
    var width: CGFloat
    var height: CGFloat
    var bandCount: Int

    /// Rounded segment rectangles in band-major order, bottom segment first.
    func makeSegments(segmentCount: Int) -> [Path] {
        let gapX: CGFloat = 3
        let gapY: CGFloat = 2
        let bandWidth = max(2, (width - gapX * CGFloat(bandCount - 1)) / CGFloat(bandCount))
        let segmentHeight = max(1.5, (height - gapY * CGFloat(segmentCount - 1)) / CGFloat(segmentCount))
        var paths: [Path] = []
        paths.reserveCapacity(bandCount * segmentCount)
        for band in 0..<bandCount {
            for segment in 0..<segmentCount {
                let rect = CGRect(
                    x: origin + CGFloat(band) * (bandWidth + gapX),
                    y: height - CGFloat(segment + 1) * segmentHeight - CGFloat(segment) * gapY,
                    width: bandWidth,
                    height: segmentHeight
                )
                paths.append(Path(roundedRect: rect, cornerRadius: 1.2))
            }
        }
        return paths
    }
}

/// Keeps the spectrum's per-frame drawing to filling paths. Segment shapes change only with the size and
/// band count, and the labels only with the color and the frame rate, which changes about twice a second.
@MainActor
final class SpectrumVisualizerCache {
    struct Labels {
        let left: Text
        let right: Text
        let frameRateGhost: Text
        let frameRate: Text
    }

    private struct LabelKey: Equatable {
        let color: Color
        let frameRate: Int
    }

    private static let labelFont = Font.system(size: 9, weight: .bold, design: .monospaced)
    private static let frameRateFont = Font.custom("DSEG7ClassicMini-Regular", size: 7.5)
    /// Enough for both channels of a few hosts; live resizing replaces the entries instead of growing them.
    private static let segmentLayoutLimit = 8

    private var segmentsByLayout: [SpectrumSegmentLayout: [Path]] = [:]
    private var labelKey: LabelKey?
    private var cachedLabels: Labels?
    private var cachedEqualizerFont: (size: CGFloat, font: Font)?
    private(set) var segmentBuildCount = 0
    private(set) var labelBuildCount = 0

    func segments(for layout: SpectrumSegmentLayout) -> [Path] {
        if let segments = segmentsByLayout[layout] { return segments }
        if segmentsByLayout.count >= Self.segmentLayoutLimit { segmentsByLayout.removeAll(keepingCapacity: true) }
        let segments = layout.makeSegments(segmentCount: SpectrumVisualizer.segmentCount)
        segmentsByLayout[layout] = segments
        segmentBuildCount += 1
        return segments
    }

    func labels(color: Color, frameRate: Int) -> Labels {
        let key = LabelKey(color: color, frameRate: frameRate)
        if key == labelKey, let cachedLabels { return cachedLabels }
        let value = Self.formatFrameRate(frameRate)
        let labels = Labels(
            left: Text("L").font(Self.labelFont).foregroundStyle(color),
            right: Text("R").font(Self.labelFont).foregroundStyle(color),
            frameRateGhost: Text(Self.ghostText(for: value))
                .font(Self.frameRateFont)
                .foregroundStyle(color.opacity(0.08)),
            frameRate: Text(value)
                .font(Self.frameRateFont)
                .foregroundStyle(color.opacity(0.62))
        )
        labelKey = key
        cachedLabels = labels
        labelBuildCount += 1
        return labels
    }

    func equalizerFont(size: CGFloat) -> Font {
        if let cachedEqualizerFont, cachedEqualizerFont.size == size { return cachedEqualizerFont.font }
        let font = Font.custom("Dotrice-Regular", size: size)
        cachedEqualizerFont = (size, font)
        return font
    }

    static func formatFrameRate(_ frameRate: Int) -> String {
        let clampedFrameRate = min(999, max(0, frameRate))
        return clampedFrameRate < 100 ? String(format: "%02d", clampedFrameRate) : String(clampedFrameRate)
    }

    private static func ghostText(for text: String) -> String {
        String(text.map { $0.isNumber ? "8" : $0 })
    }
}

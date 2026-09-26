import SwiftUI

struct MusicAnalysisStripView: View {
    let player: PlayerViewModel
    let palette: LEDDisplayPalette
    let mediaInfoStyle: MediaInfoDisplayStyle

    private var analysis: MusicAnalysis? { player.musicAnalysis.result }
    private var time: Double { player.currentTime }
    private var duration: Double { analysis?.duration ?? player.duration }
    private var key: String {
        analysis?.keyLabel(at: time, transposition: player.isVideoMode ? 0 : player.pitchSemitones) ?? "—"
    }
    private var bpm: String {
        analysis?.displayedBPM(
            at: time,
            tempoByBeat: player.musicAnalysis.tempoByBeat,
            rate: player.isVideoMode ? 1 : player.playbackRate
        ).map(String.init) ?? "—"
    }
    private var statusText: String {
        switch player.musicAnalysis.status {
        case .idle: return ""
        case .analyzing: return L10n.string("Analyzing music…")
        case .ready: return ""
        case .unavailable: return L10n.string("Music analysis requires OS 27")
        case .failed: return L10n.string("Music analysis unavailable")
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(compact: false)
            strip(compact: true)
        }
        .foregroundStyle(palette.primaryColor)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .frame(height: 21)
        .help(
            L10n.string("Musical key, song structure and pace, tempo and beats")
                + (statusText.isEmpty ? "" : " — " + statusText)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Music analysis"))
        .accessibilityValue(Text("KEY \(key), \(bpm) BPM. \(statusText)"))
    }

    private func strip(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            HStack(spacing: 4) {
                if !compact {
                    Text("KEY").font(.system(size: 8, design: .monospaced))
                }
                Text(key)
                    .font(mediaInfoStyle.titleFont(scale: 1.25))
                    .tracking(mediaInfoStyle.textTracking)
            }
            .fixedSize(horizontal: true, vertical: false)
            timeline
                .frame(minWidth: compact ? 24 : 80)
                .overlay {
                    if !statusText.isEmpty && !compact {
                        Text(statusText)
                            .font(.system(size: 8))
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                            .background(palette.backgroundColor.opacity(0.9))
                    }
                }
            HStack(spacing: 5) {
                HStack(alignment: .bottom, spacing: 3) {
                    ZStack(alignment: .trailing) {
                        Text("888")
                            .opacity(0.08)
                            .accessibilityHidden(true)
                        Text(bpm == "—" ? "---" : bpm)
                    }
                    .font(.custom(TimeDisplayStyle.sevenSegment.fontName, size: 17))
                    Text("BPM")
                        .font(.system(size: 8, design: .monospaced))
                }
                LEDBeatIndicatorView(
                    position: analysis?.beatPosition(at: time),
                    isPlaying: player.isPlaying,
                    color: palette.primaryColor
                )
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .lineLimit(1)
    }

    private var timeline: some View {
        Canvas { context, size in
            guard duration.isFinite, duration > 0, size.width > 0 else { return }
            let position = min(1, max(0, time.isFinite ? time / duration : 0))
            let color = palette.primaryColor
            let activeSection = analysis?.sections.first { $0.contains(time) }
            if let activeSection {
                let rect = CGRect(
                    x: activeSection.start / duration * size.width, y: 0,
                    width: (activeSection.end - activeSection.start) / duration * size.width, height: size.height
                )
                context.fill(Path(rect), with: .color(color.opacity(0.08)))
            }
            let count = max(1, Int(size.width / 3))
            let levels = player.musicAnalysis.paceLevels
            for index in 0..<count {
                let sampleTime = (Double(index) + 0.5) / Double(count) * duration
                guard !levels.isEmpty,
                      let level = levels[min(levels.count - 1, index * levels.count / count)] else { continue }
                let height = max(1, level * (size.height - 3))
                let horizontalPosition = CGFloat(index) * size.width / CGFloat(count)
                let opacity = activeSection?.contains(sampleTime) == true ? 0.8 : 0.35
                context.fill(
                    Path(CGRect(x: horizontalPosition, y: size.height - height, width: 2, height: height)),
                    with: .color(color.opacity(opacity))
                )
            }
            context.fill(
                Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
                with: .color(color.opacity(0.2))
            )
            if analysis == nil {
                context.fill(
                    Path(CGRect(x: 0, y: size.height - 2, width: size.width * position, height: 2)),
                    with: .color(color.opacity(0.6))
                )
            }
            for section in analysis?.sections ?? [] {
                let horizontalPosition = section.start / duration * size.width
                context.fill(
                    Path(CGRect(x: horizontalPosition, y: 0, width: 1, height: size.height)),
                    with: .color(color.opacity(0.45))
                )
            }
            context.fill(
                Path(CGRect(x: min(size.width - 1, size.width * position), y: 0, width: 1, height: size.height)),
                with: .color(color)
            )
        }
        .padding(.vertical, 2)
    }

}

struct LEDBeatIndicatorView: View {
    let position: MusicAnalysis.BeatPosition?
    let isPlaying: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                context.fill(Path(bounds), with: .color(color.opacity(0.08)))
                if let position, (1...16).contains(position.count) {
                    let cellWidth = bounds.width / CGFloat(position.count)
                    if isPlaying && !reduceMotion && (0..<position.count).contains(position.index) {
                        let cell = CGRect(x: bounds.minX + CGFloat(position.index) * cellWidth,
                                          y: bounds.minY, width: cellWidth, height: bounds.height)
                        context.fill(Path(cell), with: .color(color))
                    }
                    var dividers = Path()
                    for index in 1..<position.count {
                        let horizontalPosition = bounds.minX + CGFloat(index) * cellWidth
                        dividers.move(to: CGPoint(x: horizontalPosition, y: bounds.minY))
                        dividers.addLine(to: CGPoint(x: horizontalPosition, y: bounds.maxY))
                    }
                    context.stroke(dividers, with: .color(color.opacity(0.55)), lineWidth: 0.6)
                }
                context.stroke(Path(bounds), with: .color(color.opacity(0.65)), lineWidth: 1)
            }
            if let position, position.count > 16 {
                Text("\(position.index + 1)/\(position.count)")
                    .font(.system(size: 8, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: 48, height: 12)
    }
}

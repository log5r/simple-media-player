import SwiftUI

struct MusicAnalysisStripView: View {
    let player: PlayerViewModel
    let palette: LEDDisplayPalette
    let mediaInfoStyle: MediaInfoDisplayStyle

    private var statusText: String {
        switch player.musicAnalysis.status {
        case .idle: return ""
        case .analyzing: return L10n.string("Analyzing music…")
        case .ready: return ""
        case .unavailable: return L10n.string("Music analysis requires OS 27")
        case .failed:
            let heading = L10n.string("Music analysis unavailable")
            guard let reason = player.musicAnalysis.failureReason else { return heading }
            return "\(heading): \(reason)"
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
        .modifier(MusicAnalysisPlaybackAccessibility(player: player, statusText: statusText))
    }

    private func strip(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            HStack(spacing: 4) {
                if !compact {
                    Text("KEY").font(.system(size: 8, design: .monospaced))
                }
                MusicAnalysisKeyView(player: player)
                    .font(mediaInfoStyle.titleFont(scale: 1.25))
                    .tracking(mediaInfoStyle.textTracking)
            }
            .fixedSize(horizontal: true, vertical: false)
            MusicAnalysisTimelineView(player: player, color: palette.primaryColor)
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
                        MusicAnalysisTempoView(player: player)
                    }
                    .font(.custom(TimeDisplayStyle.sevenSegment.fontName, size: 17))
                    Text("BPM")
                        .font(.system(size: 8, design: .monospaced))
                }
                MusicAnalysisBeatView(player: player, color: palette.primaryColor)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .lineLimit(1)
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

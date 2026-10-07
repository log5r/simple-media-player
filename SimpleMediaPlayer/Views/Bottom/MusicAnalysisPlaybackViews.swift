import SwiftUI

private struct MusicAnalysisPlaybackLabels {
    let key: String
    let bpm: String

    init(player: PlayerViewModel) {
        let analysis = player.musicAnalysis.result
        let time = player.currentTime
        key = analysis?.keyLabel(at: time, transposition: player.isVideoMode ? 0 : player.pitchSemitones) ?? "—"
        bpm = analysis?.displayedBPM(
            at: time, tempoByBeat: player.musicAnalysis.tempoByBeat,
            rate: player.isVideoMode ? 1 : player.playbackRate
        ).map(String.init) ?? "—"
    }
}

struct MusicAnalysisKeyView: View {
    let player: PlayerViewModel
    var body: some View { Text(MusicAnalysisPlaybackLabels(player: player).key) }
}

struct MusicAnalysisTempoView: View {
    let player: PlayerViewModel
    var body: some View {
        let bpm = MusicAnalysisPlaybackLabels(player: player).bpm
        Text(bpm == "—" ? "---" : bpm)
    }
}

struct MusicAnalysisBeatView: View {
    let player: PlayerViewModel
    let color: Color
    var body: some View {
        LEDBeatIndicatorView(
            position: player.musicAnalysis.result?.beatPosition(at: player.currentTime),
            isPlaying: player.isPlaying, color: color
        )
    }
}

struct MusicAnalysisPlaybackAccessibility: ViewModifier {
    let player: PlayerViewModel
    let statusText: String
    func body(content: Content) -> some View {
        let labels = MusicAnalysisPlaybackLabels(player: player)
        content.accessibilityValue(Text("KEY \(labels.key), \(labels.bpm) BPM. \(statusText)"))
    }
}

struct MusicAnalysisTimelineView: View {
    let player: PlayerViewModel
    let color: Color
    var body: some View {
        let analysis = player.musicAnalysis.result
        let time = player.currentTime
        let duration = analysis?.duration ?? player.duration
        let levels = player.musicAnalysis.paceLevels
        return Canvas { context, size in
            guard duration.isFinite, duration > 0, size.width > 0 else { return }
            let position = min(1, max(0, time.isFinite ? time / duration : 0))
            let activeSection = analysis?.sections.first { $0.contains(time) }
            if let activeSection {
                let rect = CGRect(
                    x: activeSection.start / duration * size.width, y: 0,
                    width: (activeSection.end - activeSection.start) / duration * size.width, height: size.height
                )
                context.fill(Path(rect), with: .color(color.opacity(0.08)))
            }
            let count = max(1, Int(size.width / 3))
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

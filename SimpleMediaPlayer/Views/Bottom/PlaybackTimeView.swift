import SwiftUI

/// Read the clock in this leaf, so the LED panel does not observe playback ticks.
struct PlaybackTimeView: View {
    let player: PlayerViewModel
    let color: Color
    var scale: CGFloat = 1
    let shadowOpacity: Double
    let shadowRadius: CGFloat

    var body: some View {
        SevenSegmentTimeView(
            time: TimeInterval(player.elapsedSeconds), color: color, scale: scale,
            shadowOpacity: shadowOpacity, shadowRadius: shadowRadius
        )
    }
}

struct PlaybackProgressStrip: View {
    let player: PlayerViewModel
    let color: Color

    var body: some View {
        let fraction = min(max(player.currentTime / max(player.duration, 1), 0), 1)
        GeometryReader { proxy in
            Rectangle().fill(color.opacity(0.2))
                .overlay(alignment: .leading) {
                    Rectangle().fill(color)
                        .frame(width: proxy.size.width * fraction)
                }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

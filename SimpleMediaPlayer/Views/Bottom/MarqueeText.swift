import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font
    var tracking: CGFloat = 0
    var opacity: Double = 1
    var color = Color(red: 0.72, green: 0.91, blue: 0.53)
    var shadowOpacity = 0.75
    var shadowRadius: CGFloat = 2
    @State private var contentWidth: CGFloat = 0
    @State private var cycleStart = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spacing: CGFloat = 52
    private let holdDelay: TimeInterval = 2.4
    private let pointsPerSecond: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let displayText = text.isEmpty ? " " : text
            let shouldScroll = contentWidth > proxy.size.width + 1

            ZStack(alignment: .leading) {
                styledText(displayText)
                    .background {
                        GeometryReader { textProxy in
                            Color.clear.preference(key: MarqueeTextWidthKey.self, value: textProxy.size.width)
                        }
                    }
                    .hidden()

                if shouldScroll && reduceMotion == false {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                        let distance = contentWidth + spacing
                        let scrollDuration = TimeInterval(distance / pointsPerSecond)
                        let cycleDuration = holdDelay + scrollDuration + holdDelay
                        let elapsed = timeline.date.timeIntervalSince(cycleStart)
                            .truncatingRemainder(dividingBy: cycleDuration)
                        let offset = scrollOffset(elapsed: elapsed, distance: distance, scrollDuration: scrollDuration)

                        HStack(spacing: spacing) {
                            styledText(displayText)
                            styledText(displayText)
                        }
                        .offset(x: offset)
                    }
                } else {
                    styledText(displayText)
                }
            }
        }
        .clipped()
        // Clipping hides overflow but does not exclude it from hit testing.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
        .onPreferenceChange(MarqueeTextWidthKey.self) { width in
            contentWidth = width
        }
        .onChange(of: text) { _, _ in
            cycleStart = Date()
        }
    }

    private func scrollOffset(elapsed: TimeInterval, distance: CGFloat, scrollDuration: TimeInterval) -> CGFloat {
        guard elapsed >= holdDelay else { return 0 }
        let scrollingElapsed = min(scrollDuration, elapsed - holdDelay)
        return -distance * CGFloat(scrollingElapsed / max(scrollDuration, 0.001))
    }

    private func styledText(_ value: String) -> some View {
        Text(value)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(color.opacity(opacity))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .shadow(color: color.opacity(shadowOpacity), radius: shadowRadius)
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

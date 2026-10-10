import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font
    var tracking: CGFloat = 0
    var opacity: Double = 1
    var color = Color(red: 0.72, green: 0.91, blue: 0.53)
    var shadowOpacity = 0.75
    var shadowRadius: CGFloat = 2
    /// Stops scrolling, for example while playback is stopped or paused. The text then rests at its start,
    /// and scrolling restarts with the opening hold when this becomes false.
    var isScrollingPaused = false
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

                if shouldScroll && reduceMotion == false && isScrollingPaused == false {
                    let distance = contentWidth + spacing
                    let scrollDuration = TimeInterval(distance / pointsPerSecond)
                    let cycleDuration = holdDelay + scrollDuration + holdDelay
                    // Ticks only while the text moves; the holds draw a single frame each.
                    TimelineView(MarqueeTimelineSchedule(
                        cycleStart: cycleStart, holdDelay: holdDelay, scrollDuration: scrollDuration
                    )) { timeline in
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
        .onChange(of: isScrollingPaused) { _, _ in
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

/// Timeline entries for one marquee cycle: hold, scroll, hold. While the text scrolls, entries follow at the
/// frame interval. A hold needs only the entry at its start, because the offset does not change during it.
/// The closing hold shows the second copy exactly where the first one starts, so it continues into the next
/// cycle's opening hold without an entry at the cycle boundary.
nonisolated struct MarqueeTimelineSchedule: TimelineSchedule {
    var cycleStart: Date
    var holdDelay: TimeInterval
    var scrollDuration: TimeInterval
    var frameInterval: TimeInterval = 1.0 / 60

    private var cycleDuration: TimeInterval {
        holdDelay + scrollDuration + holdDelay
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(schedule: self, nextDate: startDate, animates: mode == .normal)
    }

    struct Entries: Sequence, IteratorProtocol {
        let schedule: MarqueeTimelineSchedule
        var nextDate: Date?
        let animates: Bool

        mutating func next() -> Date? {
            guard let date = nextDate else { return nil }
            nextDate = schedule.date(after: date, animates: animates)
            return date
        }
    }

    /// The entry after `date`: the next frame while scrolling, otherwise the start or end of the scroll.
    /// In low-frequency mode only those boundaries are produced.
    func date(after date: Date, animates: Bool) -> Date? {
        let cycleDuration = cycleDuration
        guard cycleDuration > 0, cycleDuration.isFinite, frameInterval > 0 else { return nil }
        // Tolerates rounding when a boundary entry is converted back into a cycle phase.
        let tolerance = 1e-6
        let elapsed = date.timeIntervalSince(cycleStart)
        let cycleIndex = (elapsed / cycleDuration).rounded(.down)
        let cycleOrigin = cycleStart.addingTimeInterval(cycleIndex * cycleDuration)
        let phase = elapsed - cycleIndex * cycleDuration
        let scrollEnd = holdDelay + scrollDuration
        if phase < holdDelay - tolerance {
            return cycleOrigin.addingTimeInterval(holdDelay)
        }
        if phase < scrollEnd - tolerance {
            let end = cycleOrigin.addingTimeInterval(scrollEnd)
            guard animates else { return end }
            return min(date.addingTimeInterval(frameInterval), end)
        }
        return cycleOrigin.addingTimeInterval(cycleDuration + holdDelay)
    }
}

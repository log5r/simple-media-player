import Foundation
import SwiftUI
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct SpectrumVisualizerCacheTests {
    @Test func segmentPathsAreReusedUntilSizeOrBandCountChanges() {
        let cache = SpectrumVisualizerCache()
        let layout = SpectrumSegmentLayout(origin: 0, width: 200, height: 60, bandCount: 16)
        let first = cache.segments(for: layout)
        #expect(first.count == 16 * SpectrumVisualizer.segmentCount)
        #expect(cache.segments(for: layout) == first)
        #expect(cache.segmentBuildCount == 1)

        var taller = layout
        taller.height = 80
        #expect(cache.segments(for: taller) != first)
        #expect(cache.segmentBuildCount == 2)

        var wider = layout
        wider.width = 240
        #expect(cache.segments(for: wider) != first)
        #expect(cache.segmentBuildCount == 3)

        var moreBands = layout
        moreBands.bandCount = 32
        #expect(cache.segments(for: moreBands).count == 32 * SpectrumVisualizer.segmentCount)
        #expect(cache.segmentBuildCount == 4)

        // Both channels of a host use different origins and stay cached together.
        var rightChannel = layout
        rightChannel.origin = 238
        _ = cache.segments(for: rightChannel)
        _ = cache.segments(for: layout)
        _ = cache.segments(for: rightChannel)
        #expect(cache.segmentBuildCount == 5)
    }

    @Test func liveResizingReplacesCachedLayoutsInsteadOfGrowing() {
        let cache = SpectrumVisualizerCache()
        for height in 40..<80 {
            _ = cache.segments(for: SpectrumSegmentLayout(
                origin: 0, width: 200, height: CGFloat(height), bandCount: 16
            ))
        }
        #expect(cache.segmentBuildCount == 40)
        let last = SpectrumSegmentLayout(origin: 0, width: 200, height: 79, bandCount: 16)
        _ = cache.segments(for: last)
        #expect(cache.segmentBuildCount == 40)
    }

    @Test func cachedSegmentsKeepTheOriginalGeometry() {
        let layout = SpectrumSegmentLayout(origin: 238, width: 181, height: 57, bandCount: 16)
        let segments = SpectrumVisualizerCache().segments(for: layout)
        let segmentCount = SpectrumVisualizer.segmentCount
        let bandWidth = max(2, (layout.width - 3 * CGFloat(layout.bandCount - 1)) / CGFloat(layout.bandCount))
        let segmentHeight = max(1.5, (layout.height - 2 * CGFloat(segmentCount - 1)) / CGFloat(segmentCount))
        for (band, segment) in [(0, 0), (5, 7), (15, 11)] {
            let rect = CGRect(
                x: layout.origin + CGFloat(band) * (bandWidth + 3),
                y: layout.height - CGFloat(segment + 1) * segmentHeight - CGFloat(segment) * 2,
                width: bandWidth,
                height: segmentHeight
            )
            #expect(segments[band * segmentCount + segment] == Path(roundedRect: rect, cornerRadius: 1.2))
        }
    }

    @Test func labelsAreRebuiltOnlyWhenTheFrameRateOrColorChanges() {
        let cache = SpectrumVisualizerCache()
        let green = Color(red: 0.72, green: 0.91, blue: 0.53)
        for _ in 0..<30 { _ = cache.labels(color: green, frameRate: 30) }
        #expect(cache.labelBuildCount == 1)
        _ = cache.labels(color: green, frameRate: 31)
        #expect(cache.labelBuildCount == 2)
        _ = cache.labels(color: .red, frameRate: 31)
        #expect(cache.labelBuildCount == 3)
        _ = cache.labels(color: .red, frameRate: 31)
        #expect(cache.labelBuildCount == 3)
    }

    @Test func frameRateKeepsItsSevenSegmentFormat() {
        #expect(SpectrumVisualizerCache.formatFrameRate(0) == "00")
        #expect(SpectrumVisualizerCache.formatFrameRate(7) == "07")
        #expect(SpectrumVisualizerCache.formatFrameRate(60) == "60")
        #expect(SpectrumVisualizerCache.formatFrameRate(120) == "120")
        #expect(SpectrumVisualizerCache.formatFrameRate(-3) == "00")
        #expect(SpectrumVisualizerCache.formatFrameRate(5_000) == "999")
    }
}

struct MarqueeTimelineScheduleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let hold: TimeInterval = 2.4
    private let scroll: TimeInterval = 5
    private var cycle: TimeInterval { hold + scroll + hold }
    private var schedule: MarqueeTimelineSchedule {
        MarqueeTimelineSchedule(cycleStart: start, holdDelay: hold, scrollDuration: scroll)
    }
    private let tolerance = 1e-6

    @Test func holdsProduceNoEntriesAndScrollingTicksAtTheFrameRate() {
        let end = start.addingTimeInterval(2 * cycle + 1)
        let dates = Array(schedule.entries(from: start, mode: .normal).prefix { $0 < end })
        #expect(dates.first == start)
        for (previous, date) in zip(dates, dates.dropFirst()) {
            #expect(date > previous)
        }
        for date in dates.dropFirst() {
            let phase = phase(of: date)
            #expect(phase >= hold - tolerance && phase <= hold + scroll + tolerance)
        }
        for cycleIndex in 0..<2 {
            let origin = start.addingTimeInterval(Double(cycleIndex) * cycle)
            let scrollStart = origin.addingTimeInterval(hold)
            let scrollEnd = origin.addingTimeInterval(hold + scroll)
            #expect(dates.contains { abs($0.timeIntervalSince(scrollStart)) < tolerance })
            #expect(dates.contains { abs($0.timeIntervalSince(scrollEnd)) < tolerance })
            let scrolling = dates.filter {
                $0 >= scrollStart.addingTimeInterval(-tolerance) && $0 <= scrollEnd.addingTimeInterval(tolerance)
            }
            #expect(scrolling.count == Int((scroll * 60).rounded(.up)) + 1)
            for (previous, date) in zip(scrolling, scrolling.dropFirst()) {
                #expect(date.timeIntervalSince(previous) <= 1.0 / 60 + tolerance)
            }
        }
        // From the end of one scroll the next entry is the start of the next one: the two holds draw nothing.
        let firstEnd = start.addingTimeInterval(hold + scroll)
        let afterEnd = dates.first { $0.timeIntervalSince(firstEnd) > tolerance }
        #expect(afterEnd.map { abs($0.timeIntervalSince(start) - (cycle + hold)) < tolerance } == true)
    }

    @Test func entriesStartingInsideAHoldWaitForTheNextScroll() {
        let openingHold = start.addingTimeInterval(1)
        var entries = schedule.entries(from: openingHold, mode: .normal).makeIterator()
        #expect(entries.next() == openingHold)
        #expect(entries.next().map { abs($0.timeIntervalSince(start) - hold) < tolerance } == true)

        let closingHold = start.addingTimeInterval(hold + scroll + 1)
        entries = schedule.entries(from: closingHold, mode: .normal).makeIterator()
        #expect(entries.next() == closingHold)
        #expect(entries.next().map { abs($0.timeIntervalSince(start) - (cycle + hold)) < tolerance } == true)

        // A restart from a date before the cycle start, such as a just-reset cycle, still waits.
        let early = start.addingTimeInterval(-0.5)
        entries = schedule.entries(from: early, mode: .normal).makeIterator()
        #expect(entries.next() == early)
        #expect(entries.next().map { abs($0.timeIntervalSince(start) - hold) < tolerance } == true)
    }

    @Test func entriesStartingMidScrollContinueAtTheFrameRate() {
        let midScroll = start.addingTimeInterval(hold + 1)
        var entries = schedule.entries(from: midScroll, mode: .normal).makeIterator()
        #expect(entries.next() == midScroll)
        #expect(entries.next().map { abs($0.timeIntervalSince(midScroll) - 1.0 / 60) < tolerance } == true)
    }

    @Test func lowFrequencyModeProducesOnlyScrollBoundaries() {
        let end = start.addingTimeInterval(2 * cycle)
        let dates = Array(schedule.entries(from: start, mode: .lowFrequency).prefix { $0 < end })
        let phases = dates.dropFirst().map(phase(of:))
        #expect(phases.count == 4)
        #expect(phases.allSatisfy { abs($0 - hold) < tolerance || abs($0 - (hold + scroll)) < tolerance })
    }

    private func phase(of date: Date) -> TimeInterval {
        let elapsed = date.timeIntervalSince(start)
        return elapsed - (elapsed / cycle).rounded(.down) * cycle
    }
}

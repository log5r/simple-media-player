import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LyricsActiveLineTests {
    /// The scan `LyricsPanelView` used before the binary search, kept as the reference behavior.
    private func linearActiveIndex(in parsed: ParsedLyrics, at time: TimeInterval) -> Int? {
        parsed.lines.lastIndex { ($0.timestamp ?? .infinity) <= time }
    }

    @Test func selectsLastLineAtOrBeforeTime() {
        let parsed = LyricsParser.parse("""
        [00:01.00]first
        [00:05.00]second
        [00:09.00]third
        """)

        #expect(parsed.activeLineIndex(at: 0) == nil)
        #expect(parsed.activeLineIndex(at: 0.99) == nil)
        #expect(parsed.activeLineIndex(at: 1) == 0)
        #expect(parsed.activeLineIndex(at: 4.99) == 0)
        #expect(parsed.activeLineIndex(at: 5) == 1)
        #expect(parsed.activeLineIndex(at: 100) == 2)
    }

    @Test func selectsLastOfLinesSharingTimestamp() {
        let parsed = LyricsParser.parse("""
        [00:02.00]before
        [00:04.00]one
        [00:04.00]two
        [00:04.00][00:06.00]three
        """)

        #expect(parsed.lines.map(\.text) == ["before", "one", "two", "three", "three"])
        #expect(parsed.activeLineIndex(at: 4) == 3)
        #expect(parsed.activeLineIndex(at: 5.5) == 3)
        #expect(parsed.activeLineIndex(at: 6) == 4)
    }

    @Test func neverSelectsUntimedLines() {
        let parsed = LyricsParser.parse("""
        [00:01.00]timed

        plain tail
        """)

        #expect(parsed.lines.map(\.timestamp) == [1, nil, nil])
        #expect(parsed.activeLineIndex(at: 1_000) == 0)

        let untimed = LyricsParser.parse("plain\nlines")
        #expect(untimed.activeLineIndex(at: 0) == nil)
        #expect(untimed.activeLineIndex(at: 1_000) == nil)
        #expect(ParsedLyrics(lines: [], hasTimeTags: false).activeLineIndex(at: 3) == nil)
    }

    @Test func rejectsNaNTime() {
        let parsed = LyricsParser.parse("[00:01.00]timed")

        #expect(parsed.activeLineIndex(at: .nan) == nil)
        #expect(parsed.activeLineIndex(at: -.infinity) == nil)
    }

    /// Plays forward, seeks backward, and jumps around a long file with repeated and untimed lines,
    /// checking each position against the original linear scan.
    @Test func matchesLinearScanAcrossForwardAndBackwardSeeks() {
        var rawLines: [String] = []
        for index in 0..<600 {
            let time = Double(index / 3) * 1.5
            let minutes = Int(time) / 60
            let seconds = time - Double(minutes * 60)
            rawLines.append(String(format: "[%02d:%05.2f]line %d", minutes, seconds, index))
            if index.isMultiple(of: 50) {
                rawLines.append("")
                rawLines.append("untimed \(index)")
            }
        }
        let parsed = LyricsParser.parse(rawLines.joined(separator: "\n"))
        #expect(parsed.hasTimeTags)

        let forward = stride(from: -1.0, through: 320, by: 1.0 / 30)
        let backward = stride(from: 320.0, through: -1, by: -0.37)
        let jumps: [TimeInterval] = [250, 3, 299.25, 0, 150, 1.5, 1.4999, 298.5, 298.5001]
        for time in Array(forward) + Array(backward) + jumps {
            #expect(parsed.activeLineIndex(at: time) == linearActiveIndex(in: parsed, at: time), "time: \(time)")
        }
    }

    @Test func parseTreatsNonFiniteTimestampsAsPlainText() {
        let parsed = LyricsParser.parse("""
        [00:03.00]real
        [nan:00]not a time
        [inf:00]also not a time
        [00:01.00]earlier
        """)

        #expect(parsed.lines.map(\.text) == ["earlier", "real", "[nan:00]not a time", "[inf:00]also not a time"])
        #expect(parsed.lines.map(\.timestamp) == [1, 3, nil, nil])
        #expect(parsed.activeLineIndex(at: 2) == 0)
        #expect(parsed.activeLineIndex(at: 10) == 1)
    }
}

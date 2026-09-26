import Foundation

nonisolated struct MusicAnalysis: Codable, Sendable {
    struct Interval: Codable, Sendable, Hashable {
        let start: Double
        let end: Double

        func contains(_ time: Double) -> Bool { start <= time && time < end }
    }

    struct Pace: Codable, Sendable {
        let interval: Interval
        let value: Double
    }

    struct Key: Codable, Sendable {
        let interval: Interval
        let pitchClass: Int
        let name: String
        let isMinor: Bool
    }

    struct BeatPosition: Equatable, Sendable {
        let count: Int
        let index: Int
    }

    var duration: Double
    var sections: [Interval] = []
    var pace: [Pace] = []
    var keys: [Key] = []
    var beats: [Double] = []
    var bars: [Double] = []
    var bpm: Double?
    var rhythmRegions: [Interval]?
    var uncertainRhythmRanges: [Interval]?

    func keyAnalysisRanges() -> [Interval] {
        guard duration.isFinite, duration > 0 else { return [] }
        let boundaries = Array(Set([0, duration] + sections.flatMap { [$0.start, $0.end] }
            .filter { $0.isFinite && $0 > 0 && $0 < duration })).sorted()
        let ranges = zip(boundaries, boundaries.dropFirst()).flatMap { start, end in
            // Equal subdivisions avoid a tiny remainder at the end of a long section.
            let count = max(1, Int(ceil((end - start) / 30)))
            return (0..<count).map { index in
                Interval(start: start + (end - start) * Double(index) / Double(count),
                         end: start + (end - start) * Double(index + 1) / Double(count))
            }
        }
        return ranges.count > 1 ? ranges : []
    }

    mutating func applyKeyExcerpt(_ localKeys: [Key], range: Interval) {
        guard range.start.isFinite, range.end.isFinite,
              range.start >= 0, range.end <= duration, range.end > range.start else { return }
        for key in localKeys {
            guard key.interval.start.isFinite, key.interval.end.isFinite,
                  (0..<12).contains(key.pitchClass), !key.name.isEmpty else { continue }
            let start = max(range.start, key.interval.start)
            let end = min(range.end, key.interval.end)
            guard end > start else { continue }
            // Replace only detected spans, preserving the original result in gaps.
            keys = keys.flatMap { existing -> [Key] in
                guard existing.interval.start < end, existing.interval.end > start else { return [existing] }
                var fragments: [Key] = []
                if existing.interval.start < start {
                    fragments.append(Key(interval: .init(start: existing.interval.start, end: start),
                        pitchClass: existing.pitchClass, name: existing.name, isMinor: existing.isMinor))
                }
                if existing.interval.end > end {
                    fragments.append(Key(interval: .init(start: end, end: existing.interval.end),
                        pitchClass: existing.pitchClass, name: existing.name, isMinor: existing.isMinor))
                }
                return fragments
            }
            keys.append(Key(interval: .init(start: start, end: end),
                pitchClass: key.pitchClass, name: key.name, isMinor: key.isMinor))
        }
        keys.sort { $0.interval.start < $1.interval.start }
    }

    struct RhythmExcerpt: Sendable {
        let range: Interval
        let context: Interval
        let beats: [Double]
        let bars: [Double]
    }

    func rhythmAnalysisRanges() -> [Interval] {
        guard duration.isFinite, duration > 60 else { return [] }
        return stride(from: 0.0, to: duration, by: 30).map { start in
            Interval(start: start, end: min(start + 30, duration))
        }
    }

    func rhythmAnalysisContext(for range: Interval) -> Interval {
        // Overlap supplies musical context without using one tempo estimate for the entire song.
        let start = max(0, min(range.start - 15, duration - 60))
        return Interval(start: start, end: min(duration, start + 60))
    }

    mutating func applyRhythmExcerpts(_ excerpts: [RhythmExcerpt]) {
        let excerpts = excerpts.sorted { $0.range.start < $1.range.start }.compactMap { excerpt -> RhythmExcerpt? in
            guard excerpt.range.start.isFinite, excerpt.range.end.isFinite,
                  excerpt.context.start.isFinite, excerpt.context.end.isFinite,
                  excerpt.range.start >= 0, excerpt.range.end <= duration,
                  excerpt.range.end > excerpt.range.start,
                  excerpt.context.start <= excerpt.range.start,
                  excerpt.context.end >= excerpt.range.end else { return nil }
            func clean(_ times: [Double]) -> [Double] {
                Array(Set(times.filter {
                    $0.isFinite && $0 >= 0 && $0 < duration && excerpt.context.contains($0)
                })).sorted()
            }
            let beats = clean(excerpt.beats)
            guard beats.filter({ excerpt.range.contains($0) }).count >= 2 else { return nil }
            return RhythmExcerpt(range: excerpt.range, context: excerpt.context,
                                 beats: beats, bars: alignedBars(clean(excerpt.bars), beats: beats))
        }
        guard !excerpts.isEmpty else { return }

        // Preserve complete overlapping results until all seams have been chosen.
        var sources: [RhythmExcerpt] = []
        var end = 0.0
        for excerpt in excerpts {
            guard excerpt.range.start >= end else { continue }
            if end < excerpt.range.start {
                sources.append(RhythmExcerpt(range: .init(start: end, end: excerpt.range.start),
                    context: .init(start: 0, end: duration), beats: beats, bars: alignedBars(bars, beats: beats)))
            }
            sources.append(excerpt)
            end = excerpt.range.end
        }
        if end < duration {
            sources.append(RhythmExcerpt(range: .init(start: end, end: duration),
                context: .init(start: 0, end: duration), beats: beats, bars: alignedBars(bars, beats: beats)))
        }

        var starts = sources.map { $0.range.start }
        var ends = sources.map { $0.range.end }
        var uncertainSeams: [Double] = []
        for index in sources.indices.dropFirst() {
            let left = sources[index - 1]
            let right = sources[index]
            let target = right.range.start
            // Keep seams ordered even for very short final ranges.
            let search = Interval(start: max(left.context.start, right.context.start,
                                            left.range.start, starts[index - 1]),
                                  end: min(left.context.end, right.context.end, right.range.end))
            if let seam = rhythmSeam(left: left, right: right, near: target, within: search) {
                ends[index - 1] = seam.left
                starts[index] = seam.right
                if !seam.isBar { uncertainSeams.append(seam.right) }
            } else {
                // Conflicting detections cannot establish a reliable meter across this seam.
                uncertainSeams.append(target)
            }
        }

        beats = []
        bars = []
        rhythmRegions = []
        for index in sources.indices {
            let source = sources[index]
            let interval = Interval(start: starts[index], end: ends[index])
            beats += source.beats.filter { interval.contains($0) }
            bars += source.bars.filter { interval.contains($0) }
            // Use the incoming timestamp for ownership; do not interpolate detected beats.
            rhythmRegions?.append(Interval(start: starts[index],
                end: index + 1 < sources.count ? starts[index + 1] : duration))
        }
        beats = Array(Set(beats)).sorted()
        bars = Array(Set(bars)).sorted()
        uncertainRhythmRanges = uncertainSeams.map { seam in
            let previous = insertionIndex(in: bars, for: seam) - 1
            let next = insertionIndex(in: bars, for: seam, afterEqual: true)
            return Interval(start: previous >= 0 ? bars[previous] : 0,
                            end: next < bars.count ? bars[next] : duration)
        }
    }

    private func alignedBars(_ bars: [Double], beats: [Double]) -> [Double] {
        // Bar and beat timestamps may differ slightly. Keep beat timing unchanged.
        Array(Set(bars.map { bar in
            let index = insertionIndex(in: beats, for: bar)
            guard let nearest = [index - 1, index].filter({ beats.indices.contains($0) })
                .min(by: { abs(beats[$0] - bar) < abs(beats[$1] - bar) }) else { return bar }
            let before = nearest > 0 ? beats[nearest] - beats[nearest - 1] : .infinity
            let after = nearest + 1 < beats.count ? beats[nearest + 1] - beats[nearest] : .infinity
            return abs(beats[nearest] - bar) <= min(0.08, 0.2 * min(before, after)) ? beats[nearest] : bar
        })).sorted()
    }

    private struct RhythmSeam {
        let left: Double
        let right: Double
        let isBar: Bool
    }

    private func rhythmSeam(left: RhythmExcerpt, right: RhythmExcerpt,
                            near target: Double, within overlap: Interval) -> RhythmSeam? {
        func spacing(_ beats: [Double], at index: Int) -> Double {
            min(beats[index] - beats[index - 1], beats[index + 1] - beats[index])
        }
        func nearest(_ time: Double, in values: [Double]) -> Int? {
            let index = insertionIndex(in: values, for: time)
            return [index - 1, index].filter { values.indices.contains($0) }
                .min { abs(values[$0] - time) < abs(values[$1] - time) }
        }
        func isDownbeat(_ time: Double, bars: [Double], tolerance: Double) -> Bool {
            guard let index = nearest(time, in: bars) else { return false }
            return abs(bars[index] - time) <= tolerance
        }
        var candidates: [RhythmSeam] = []
        for rightIndex in right.beats.indices where rightIndex > 0 && rightIndex + 1 < right.beats.count {
            let time = right.beats[rightIndex]
            guard overlap.contains(time), let leftIndex = nearest(time, in: left.beats),
                  leftIndex > 0, leftIndex + 1 < left.beats.count,
                  overlap.contains(left.beats[leftIndex]) else { continue }
            let tolerance = min(
                0.08,
                0.2 * min(spacing(left.beats, at: leftIndex), spacing(right.beats, at: rightIndex))
            )
            // Match surrounding beats too: a single coincident beat can hide half/double tempo.
            guard (-1...1).allSatisfy({ offset in
                overlap.contains(left.beats[leftIndex + offset]) &&
                overlap.contains(right.beats[rightIndex + offset]) &&
                abs(left.beats[leftIndex + offset] - right.beats[rightIndex + offset]) <= tolerance
            }) else { continue }
            let leftIsBar = isDownbeat(left.beats[leftIndex], bars: left.bars, tolerance: tolerance)
            let rightIsBar = isDownbeat(time, bars: right.bars, tolerance: tolerance)
            // Cut at the actual bar timestamps when both analyses identify the downbeat.
            if leftIsBar && rightIsBar,
               let leftBarIndex = nearest(left.beats[leftIndex], in: left.bars),
               let rightBarIndex = nearest(time, in: right.bars),
               overlap.contains(left.bars[leftBarIndex]), overlap.contains(right.bars[rightBarIndex]) {
                // Include a downbeat that is slightly earlier than its reported bar boundary.
                candidates.append(RhythmSeam(left: min(left.beats[leftIndex], left.bars[leftBarIndex]),
                    right: min(time, right.bars[rightBarIndex]), isBar: true))
            } else {
                candidates.append(RhythmSeam(left: left.beats[leftIndex], right: time, isBar: false))
            }
        }
        return candidates.min {
            if $0.isBar != $1.isBar { return $0.isBar }
            let firstDistance = abs($0.right - target)
            let secondDistance = abs($1.right - target)
            if firstDistance == secondDistance { return $0.right > $1.right }
            return firstDistance < secondDistance
        }
    }

    func keyLabel(at time: Double, transposition: Int) -> String? {
        guard let key = keys.first(where: { $0.interval.contains(time) }) else { return nil }
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let index = ((key.pitchClass + transposition % 12) % 12 + 12) % 12
        return (transposition == 0 ? key.name : names[index]) + (key.isMinor ? "m" : "")
    }

    func beatPosition(at time: Double) -> BeatPosition? {
        guard time.isFinite, time >= 0, time < duration,
              !(uncertainRhythmRanges ?? []).contains(where: { $0.contains(time) }) else { return nil }
        let barIndex = insertionIndex(in: bars, for: time, afterEqual: true) - 1
        guard barIndex >= 0 else { return nil }
        let end = barIndex + 1 < bars.count ? bars[barIndex + 1] : duration
        let first = insertionIndex(in: beats, for: bars[barIndex])
        let limit = insertionIndex(in: beats, for: end)
        let current = insertionIndex(in: beats, for: time, afterEqual: true) - 1
        guard limit > first, current >= first, current < limit else { return nil }
        return BeatPosition(count: limit - first, index: current - first)
    }

    private func insertionIndex(in values: [Double], for time: Double, afterEqual: Bool = false) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = low + (high - low) / 2
            if values[middle] < time || (afterEqual && values[middle] == time) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    // Build once off the main actor; rendering must not scan the full song per pixel.
    func paceOverview(sampleCount: Int = 256) -> [Double?] {
        guard duration.isFinite, duration > 0, sampleCount > 0 else { return [] }
        let ranges = pace.filter { $0.value.isFinite && $0.interval.start.isFinite && $0.interval.end.isFinite }
            .sorted { $0.interval.start < $1.interval.start }
        guard let peak = ranges.map(\.value).max(), peak > 0 else { return [] }
        var index = 0
        return (0..<sampleCount).map { sample in
            let time = (Double(sample) + 0.5) / Double(sampleCount) * duration
            while index < ranges.count && ranges[index].interval.end <= time { index += 1 }
            guard index < ranges.count, ranges[index].interval.contains(time) else { return nil }
            return min(1, max(0, ranges[index].value / peak))
        }
    }

    // Each entry uses only the last four completed beat intervals, independent of meter.
    func tempoByBeat() -> [Double?] {
        var result = [Double?](repeating: nil, count: beats.count)
        var intervals: [Double] = []
        let regions = rhythmRegions ?? []
        for index in beats.indices.dropFirst() {
            let region = regions.firstIndex { $0.contains(beats[index]) }
            let previousRegion = regions.firstIndex { $0.contains(beats[index - 1]) }
            // Independently analyzed excerpts need not share the same beat phase.
            if region != previousRegion {
                intervals.removeAll(keepingCapacity: true)
                continue
            }
            let interval = beats[index] - beats[index - 1]
            guard interval.isFinite, interval > 0 else {
                intervals.removeAll(keepingCapacity: true)
                continue
            }
            intervals.append(interval)
            if intervals.count > 4 { intervals.removeFirst() }
            let tempo = 60 * Double(intervals.count) / intervals.reduce(0, +)
            if tempo.isFinite, tempo > 0 { result[index] = tempo }
        }
        for region in regions {
            let first = insertionIndex(in: beats, for: region.start)
            if first + 1 < beats.count, region.contains(beats[first + 1]) {
                result[first] = result[first + 1]
            }
        }
        return result
    }

    func displayedBPM(at time: Double = 0, tempoByBeat: [Double?] = [], rate: Double) -> Int? {
        guard time.isFinite, time >= 0 else { return nil }
        let index = insertionIndex(in: beats, for: time, afterEqual: true) - 1
        let localBPM = tempoByBeat.count == beats.count && tempoByBeat.indices.contains(index)
            ? tempoByBeat[index] : nil
        let bpm = localBPM ?? bpm
        guard let bpm, bpm.isFinite, bpm > 0, rate.isFinite else { return nil }
        return Int(min(999, max(1, (bpm * min(2, max(0.5, rate))).rounded())))
    }
}

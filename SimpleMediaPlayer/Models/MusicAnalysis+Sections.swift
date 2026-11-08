import Foundation

/// Positions for the Previous Section and Next Section buttons.
nonisolated extension MusicAnalysis {
    /// Section edges closer than this to the boundary before them or to the end of the song are left out.
    /// The analysis can place the first section a few milliseconds after the start and end the last one just
    /// before the end of the song, and moving there would not reach a new part of the song.
    static let minimumSectionGap: Double = 0.5

    /// The song start and each section edge within the song, sorted. Empty when the analysis found no section
    /// edge to move to, so that the buttons move between tracks instead.
    func sectionBoundaries() -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let edges = sections.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .flatMap { [$0.start, $0.end] }
            .filter { $0 >= 0 && $0 <= duration - Self.minimumSectionGap }
            .sorted()
        var boundaries: [Double] = [0]
        for edge in edges where edge - boundaries[boundaries.count - 1] >= Self.minimumSectionGap {
            boundaries.append(edge)
        }
        return boundaries.count > 1 ? boundaries : []
    }

    func previousSectionStart(before time: Double, restartThreshold: Double = 2) -> Double? {
        Self.previousSectionStart(in: sectionBoundaries(), before: time, restartThreshold: restartThreshold)
    }

    func nextSectionStart(after time: Double) -> Double? {
        Self.nextSectionStart(in: sectionBoundaries(), after: time)
    }

    /// Restarts the section that contains `time`, or moves to the one before it within `restartThreshold` of
    /// its start, in the same way that Previous Track restarts a track that has played for a few seconds.
    /// `boundaries` must be sorted, as `sectionBoundaries()` returns them.
    static func previousSectionStart(in boundaries: [Double], before time: Double,
                                     restartThreshold: Double = 2) -> Double? {
        guard time.isFinite, let current = boundaries.lastIndex(where: { $0 <= time }) else { return nil }
        if time - boundaries[current] >= restartThreshold { return boundaries[current] }
        return current > boundaries.startIndex ? boundaries[current - 1] : nil
    }

    /// The first boundary after `time`. A boundary that a seek has just reached is skipped by the caller,
    /// which passes the seek target while the playback clock has not caught up with it.
    static func nextSectionStart(in boundaries: [Double], after time: Double) -> Double? {
        guard time.isFinite else { return nil }
        return boundaries.first { $0 > time }
    }
}

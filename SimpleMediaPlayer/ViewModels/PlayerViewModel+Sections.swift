import Foundation

/// Moving between the sections that music analysis found in the current audio track. The transport buttons
/// use these instead of Previous Track and Next Track while the section navigation setting is on.
extension PlayerViewModel {
    /// A seek made by section navigation. The audio engine seeks asynchronously, after a short fade, and until
    /// then reports the time before the seek. Keeping the target lets presses in quick succession continue from
    /// it instead of from that earlier time. `seek(to:)` clears it, so any other seek replaces it.
    struct SectionSeek {
        /// The engine is taken to have reached the target when it reports a time this close to it.
        static let arrivalTolerance: TimeInterval = 0.25
        /// The clock follows the engine again after this long even if it has not reported the target, so that
        /// a seek the engine never completes cannot freeze the display.
        static let pendingTimeout: TimeInterval = 1
        /// The engine places a seek on a whole frame, so it can report a time just before the target.
        static let frameRoundingTolerance: TimeInterval = 0.05

        let itemID: UUID
        let playbackGeneration: UInt64
        let target: TimeInterval
        let deadline: TimeInterval
        var isPending = true

        func hasArrived(at time: TimeInterval) -> Bool {
            time >= target - Self.frameRoundingTolerance && time <= target + Self.arrivalTolerance
        }
    }

    /// True when the analysis of the current audio track has found sections to move between. This does not
    /// read the playback time, so views that use it are not redrawn on every clock tick.
    var hasMusicSections: Bool {
        currentItem != nil && !isVideoMode && !musicAnalysis.sectionBoundaries.isEmpty
    }

    /// Previous Section falls back to Previous Track without sections or near the start of the first one.
    var canPlayPreviousSection: Bool {
        hasMusicSections || canPlayPrevious
    }

    /// Next Section falls back to Next Track without sections or after the last boundary, so it is disabled
    /// only when neither a later boundary nor a next track exists.
    var canSkipToNextSection: Bool {
        (hasMusicSections && hasNextSectionBoundary) || canSkipToNext
    }

    /// Moves to the start of the current section, or to the previous one near its start. Without a section
    /// boundary before the playback position, this behaves like `previous()`.
    func previousSection() {
        guard hasMusicSections,
              let target = MusicAnalysis.previousSectionStart(
                  in: musicAnalysis.sectionBoundaries, before: sectionNavigationTime
              ) else {
            previous()
            return
        }
        seekToSection(target)
    }

    /// Moves to the start of the next section. After the last boundary this moves to the next track, and at
    /// the end of the queue it does nothing instead of stopping playback.
    func nextSection() {
        if hasMusicSections,
           let target = MusicAnalysis.nextSectionStart(
               in: musicAnalysis.sectionBoundaries, after: sectionNavigationTime
           ) {
            seekToSection(target)
        } else if canSkipToNext {
            next()
        }
    }

    /// The position section navigation starts from. Just after a section seek that the engine placed slightly
    /// before its target, this is the target, so the boundary just reached is not chosen again.
    var sectionNavigationTime: TimeInterval {
        let time = currentTime
        guard let seek = currentSectionSeek, time < seek.target,
              time >= seek.target - SectionSeek.frameRoundingTolerance else { return time }
        return seek.target
    }

    /// The time the playback clock shows for `engineTime`. While a section seek has not reached the engine,
    /// the clock keeps showing its target rather than the time before the seek.
    func clockTimeAfterSectionSeek(_ engineTime: TimeInterval) -> TimeInterval {
        guard let seek = sectionSeek, seek.isPending else { return engineTime }
        guard currentSectionSeek != nil else {
            sectionSeek = nil
            return engineTime
        }
        if seek.hasArrived(at: engineTime) || ProcessInfo.processInfo.systemUptime >= seek.deadline {
            sectionSeek?.isPending = false
            return engineTime
        }
        return seek.target
    }

    /// Sets `hasNextSectionBoundary`, true while a section boundary lies after the playback position. It is
    /// assigned only when it changes, so views that read it are not redrawn on every clock tick.
    func updateNextSectionAvailability() {
        let available = musicAnalysis.sectionBoundaries.last.map { sectionNavigationTime < $0 } ?? false
        if hasNextSectionBoundary != available { hasNextSectionBoundary = available }
    }

    /// The section seek, if it was made in the current playback of the current track.
    private var currentSectionSeek: SectionSeek? {
        guard let seek = sectionSeek, seek.itemID == currentItem?.id,
              seek.playbackGeneration == playbackGeneration else { return nil }
        return seek
    }

    private func seekToSection(_ time: TimeInterval) {
        guard let itemID = currentItem?.id else { return }
        seek(to: time)
        sectionSeek = SectionSeek(
            itemID: itemID, playbackGeneration: playbackGeneration, target: currentTime,
            deadline: ProcessInfo.processInfo.systemUptime + SectionSeek.pendingTimeout
        )
    }
}

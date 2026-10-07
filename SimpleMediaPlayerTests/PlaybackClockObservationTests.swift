import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct PlaybackClockObservationTests {
    @Test func standardLEDDoesNotObserveThePlaybackClock() {
        let player = makePlayerFixture().player
        let changes = ClockObservationChanges()
        withObservationTracking {
            _ = LEDDisplayView(player: player).body
        } onChange: {
            changes.record()
        }

        player.currentTime = 0.1

        #expect(changes.count == 0)
    }

    @Test(arguments: [LEDDisplayLayout.phoneDeck, .phoneStrip])
    func phoneLEDDoesNotObserveThePlaybackClock(_ layout: LEDDisplayLayout) {
        let player = makePlayerFixture().player
        let changes = observe {
            _ = PhoneLEDContent(
                player: player, palette: palette, mediaInfoStyle: .default,
                layout: layout, visualizerHeight: 40
            ).body
        }

        player.currentTime = 1.1
        player.duration = 30

        #expect(changes.count == 0)
    }

    @Test func analysisLayoutDoesNotObserveThePlaybackClock() {
        let player = makePlayerFixture().player
        let changes = observe {
            _ = MusicAnalysisStripView(player: player, palette: palette, mediaInfoStyle: .default).body
        }

        player.currentTime = 1.1
        player.duration = 30

        #expect(changes.count == 0)
    }

    @Test func timeDisplayObservesWholeSecondsWhileClockRetainsFractions() {
        let player = makePlayerFixture().player
        let seconds = observe {
            _ = PlaybackTimeView(player: player, color: .green, shadowOpacity: 0.8, shadowRadius: 3).body
        }
        let fractions = observe { _ = player.currentTime }

        player.currentTime = 0.1
        player.currentTime = 0.9
        #expect(seconds.count == 0)
        #expect(fractions.count == 1)

        player.currentTime = 1
        #expect(seconds.count == 1)
        #expect(player.elapsedSeconds == 1)
    }

    @Test func previousAvailabilityOnlyChangesAtTheRestartBoundary() {
        let fixture = playingFixture()
        let player = fixture.player
        let changes = observe { _ = player.canPlayPrevious }

        for tick in 1...89 { player.currentTime = Double(tick) / 30 }
        #expect(changes.count == 0)
        #expect(!player.canPlayPrevious)

        player.currentTime = 3
        #expect(changes.count == 1)
        #expect(player.canPlayPrevious)
        let restartChanges = observe { _ = player.canPlayPrevious }
        player.currentTime = 3.1
        player.currentTime = 20
        #expect(restartChanges.count == 0)

        player.previous()
        #expect(restartChanges.count == 1)
        #expect(player.currentTime == 0)
        #expect(!player.canPlayPrevious)
        #expect(fixture.audio.seekRequests.last?.time == 0)
    }

    @Test func clockPollingDoesNotRepublishUnchangedTimeOrKnownDuration() {
        let fixture = playingFixture()
        let player = fixture.player
        let changes = observe { _ = (player.currentTime, player.duration) }

        for _ in 0..<30 { player.synchronizePlaybackClock() }
        #expect(changes.count == 0)

        fixture.audio.currentTime = 0.125
        player.synchronizePlaybackClock()
        #expect(changes.count == 1)
        #expect(player.currentTime == 0.125)
        #expect(player.duration == 30)
    }

    @Test func unknownDurationIsLoadedOnce() {
        let fixture = playingFixture()
        fixture.player.duration = 0
        fixture.audio.duration = 50
        fixture.player.synchronizePlaybackClock()
        #expect(fixture.player.duration == 50)
        let changes = observe { _ = fixture.player.duration }
        fixture.audio.duration = 60
        fixture.player.synchronizePlaybackClock()
        #expect(changes.count == 0)
        #expect(fixture.player.duration == 50)
    }

    @Test func pauseSeekStopAndReloadKeepCoarseClockStateInSync() {
        let fixture = playingFixture()
        let player = fixture.player
        let item = player.currentItem!
        player.seek(to: 9.5)
        player.pause()
        #expect(player.elapsedSeconds == 9)
        #expect(player.canPlayPrevious)
        player.seek(to: 2.9)
        #expect(player.elapsedSeconds == 2)
        #expect(!player.canPlayPrevious)
        #expect(player.isPaused)
        player.resume()
        player.seek(to: 20)
        player.stop()
        #expect(player.elapsedSeconds == 0)
        #expect(!player.canPlayPrevious)
        player.seek(to: 9)
        player.play(item: item, in: [item])
        #expect(player.elapsedSeconds == 0)
        #expect(!player.canPlayPrevious)
        player.seek(to: 9)
        player.clearCurrentItem()
        #expect(player.elapsedSeconds == 0)
        #expect(!player.canPlayPrevious)
    }

    @Test func precedingQueueItemEnablesPreviousBeforeThreeSeconds() {
        let fixture = playingFixture()
        let first = fixture.player.currentItem!
        let second = MediaItem(
            title: "Second", duration: 30, isVideo: false, bookmarkData: Data([1]), fileName: "2.mp3"
        )
        fixture.resolver.urlsByID[second.id] = URL(fileURLWithPath: "/tmp/2.mp3")
        fixture.player.play(item: second, in: [first, second])
        let changes = observe { _ = fixture.player.canPlayPrevious }
        fixture.player.currentTime = 0.1
        #expect(changes.count == 0)
        #expect(fixture.player.canPlayPrevious)
        fixture.player.previous()
        #expect(fixture.player.currentItem?.id == first.id)
    }

    @Test func videoClockRetainsSubsecondPrecision() async {
        let fixture = playingFixture(isVideo: true)
        for _ in 0..<20 {
            await Task.yield()
            if fixture.player.isPlaying { break }
        }
        fixture.video.currentTime = 0.125
        fixture.player.synchronizePlaybackClock()
        #expect(fixture.player.currentTime == 0.125)
        fixture.video.currentTime = 0.25
        fixture.player.synchronizePlaybackClock()
        #expect(fixture.player.currentTime == 0.25)
        #expect(fixture.player.elapsedSeconds == 0)
    }

    private var palette: LEDDisplayPalette {
        .resolved(
            styleRaw: "dark", darkForegroundHex: AppSettingsDefault.ledColorHex,
            backlitForegroundHex: AppSettingsDefault.ledBacklitForegroundColorHex,
            backlightHex: AppSettingsDefault.ledBacklightColorHex
        )
    }

    private func observe(_ read: () -> Void) -> ClockObservationChanges {
        let changes = ClockObservationChanges()
        withObservationTracking(read) { changes.record() }
        return changes
    }

    private func playingFixture(isVideo: Bool = false) -> PlaybackClockFixture {
        PlaybackClockFixture(isVideo: isVideo)
    }

}

private final class ClockObservationChanges: Sendable {
    private let storage = Mutex(0)
    var count: Int { storage.withLock { $0 } }
    func record() { storage.withLock { $0 += 1 } }
}

@MainActor
private struct PlaybackClockFixture {
    let player: PlayerViewModel
    let audio: FakeAudioEngine
    let video: FakeVideoService
    let resolver: FakeMediaURLResolver

    init(isVideo: Bool) {
        let item = MediaItem(
            title: "Clock", duration: 30, isVideo: isVideo, bookmarkData: Data([1]), fileName: "clock.mp3"
        )
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/clock.mp3")])
        player = fixture.player
        audio = fixture.audio
        video = fixture.video
        resolver = fixture.resolver
        player.play(item: item, in: [item])
    }
}

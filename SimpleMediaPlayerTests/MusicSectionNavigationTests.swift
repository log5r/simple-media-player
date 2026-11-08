import Foundation
import Testing
@testable import SimpleMediaPlayer

struct MusicSectionBoundaryTests {
    private let analysis = MusicAnalysis(duration: 100, sections: [
        .init(start: 10, end: 30), .init(start: 30, end: 60), .init(start: 70, end: 100),
        .init(start: .nan, end: 50)
    ])

    @Test func boundariesIncludeSongStartAndSectionEdgesWithinTheSong() {
        #expect(analysis.sectionBoundaries() == [0, 10, 30, 60, 70])
        #expect(MusicAnalysis(duration: 100).sectionBoundaries().isEmpty)
        #expect(MusicAnalysis(duration: .nan, sections: [.init(start: 0, end: 10)]).sectionBoundaries().isEmpty)
    }

    /// Edges as the analysis reports them: the first section starts just after the song, and the last one ends
    /// just before its end.
    @Test func boundariesLeaveOutEdgesThatWouldNotReachANewPartOfTheSong() {
        let analysis = MusicAnalysis(duration: 140.077, sections: [
            .init(start: 0.015, end: 16.015), .init(start: 16.015, end: 16.2), .init(start: 16.2, end: 134.015),
            .init(start: 134.015, end: 140.011)
        ])
        #expect(analysis.sectionBoundaries() == [0, 16.015, 134.015])
        #expect(MusicAnalysis(duration: 100, sections: [.init(start: 0.01, end: 99.9)]).sectionBoundaries().isEmpty)
    }

    @Test func nextChoosesTheFirstBoundaryAfterThePosition() {
        #expect(analysis.nextSectionStart(after: 0) == 10)
        #expect(analysis.nextSectionStart(after: 9.5) == 10)
        #expect(analysis.nextSectionStart(after: 9.9) == 10)
        #expect(analysis.nextSectionStart(after: 10) == 30)
        #expect(analysis.nextSectionStart(after: 59.9) == 60)
        #expect(analysis.nextSectionStart(after: 65) == 70)
        #expect(analysis.nextSectionStart(after: 70) == nil)
        #expect(analysis.nextSectionStart(after: .nan) == nil)
    }

    @Test func previousRestartsTheSectionUnlessNearItsStart() {
        #expect(analysis.previousSectionStart(before: 45) == 30)
        #expect(analysis.previousSectionStart(before: 31) == 10)
        #expect(analysis.previousSectionStart(before: 30) == 10)
        #expect(analysis.previousSectionStart(before: 11) == 0)
        #expect(analysis.previousSectionStart(before: 1.5) == nil)
        #expect(analysis.previousSectionStart(before: .nan) == nil)
    }

    @Test func previousNearTheStartOfAShortSectionMovesToTheSectionJustBefore() {
        let short = MusicAnalysis(duration: 100, sections: [
            .init(start: 0, end: 10), .init(start: 10, end: 11), .init(start: 11, end: 100)
        ])
        #expect(short.previousSectionStart(before: 11.5) == 10)
        #expect(short.previousSectionStart(before: 10.5) == 0)
        #expect(short.previousSectionStart(before: 13.5) == 11)
    }
}

@MainActor
struct PlayerSectionNavigationTests {
    private nonisolated static let sections: [MusicAnalysis.Interval] = [
        .init(start: 0, end: 20), .init(start: 20, end: 50), .init(start: 50, end: 100)
    ]

    private struct Fixture {
        let player: PlayerViewModel
        let audio: FakeAudioEngine
        let items: [MediaItem]
        let urls: [UUID: URL]
    }

    private func makeFixture(sections: [MusicAnalysis.Interval] = sections, itemCount: Int = 2) -> Fixture {
        let items = (0..<itemCount).map {
            MediaItem(title: "Track \($0)", duration: 100, isVideo: false, bookmarkData: Data(), fileName: "\($0).wav")
        }
        let urls = Dictionary(uniqueKeysWithValues: items.enumerated().map {
            ($1.id, URL(fileURLWithPath: "/tmp/section-\($0).wav"))
        })
        let controller = MusicAnalysisController { _ in MusicAnalysis(duration: 100, sections: sections) }
        let fixture = makePlayerFixture(urlsByID: urls, musicAnalysis: controller)
        return Fixture(player: fixture.player, audio: fixture.audio, items: items, urls: urls)
    }

    private func play(_ index: Int, in fixture: Fixture) async {
        let item = fixture.items[index]
        fixture.player.play(item: item, in: fixture.items)
        // Wait for the analysis that playback started, through the same controller.
        await fixture.player.musicAnalysis.load(url: fixture.urls[item.id]!)?.value
    }

    @available(macOS 27, iOS 27, *)
    @Test func nextSectionSeeksWithinTheTrackThenAdvancesAfterTheLastBoundary() async {
        let fixture = makeFixture()
        await play(0, in: fixture)
        #expect(fixture.player.hasMusicSections)

        fixture.player.currentTime = 5
        fixture.player.nextSection()
        #expect(fixture.audio.seekRequests.last?.time == 20)
        #expect(fixture.player.currentTime == 20)

        fixture.player.nextSection()
        #expect(fixture.audio.seekRequests.last?.time == 50)

        fixture.player.currentTime = 60
        fixture.player.nextSection()
        #expect(fixture.player.currentItem?.id == fixture.items[1].id)
    }

    @available(macOS 27, iOS 27, *)
    @Test func nextSectionDoesNotStopAtTheEndOfTheQueue() async {
        let fixture = makeFixture(itemCount: 1)
        await play(0, in: fixture)
        fixture.player.currentTime = 60
        let seeks = fixture.audio.seekRequests.count
        #expect(!fixture.player.canSkipToNextSection)
        fixture.player.nextSection()
        #expect(fixture.player.currentItem?.id == fixture.items[0].id)
        #expect(fixture.audio.seekRequests.count == seeks)
    }

    @available(macOS 27, iOS 27, *)
    @Test func previousSectionRestartsSectionThenFallsBackToPreviousTrack() async {
        let fixture = makeFixture()
        await play(1, in: fixture)

        fixture.player.currentTime = 30
        fixture.player.previousSection()
        #expect(fixture.audio.seekRequests.last?.time == 20)

        fixture.player.previousSection()
        #expect(fixture.audio.seekRequests.last?.time == 0)

        fixture.player.previousSection()
        #expect(fixture.player.currentItem?.id == fixture.items[0].id)
    }

    @available(macOS 27, iOS 27, *)
    @Test func withoutSectionsTheButtonsMoveBetweenTracks() async {
        let fixture = makeFixture(sections: [])
        await play(0, in: fixture)
        #expect(!fixture.player.hasMusicSections)
        #expect(!fixture.player.canPlayPreviousSection)
        #expect(fixture.player.canSkipToNextSection)

        fixture.player.currentTime = 10
        fixture.player.nextSection()
        #expect(fixture.player.currentItem?.id == fixture.items[1].id)
    }

    @Test func noCurrentItemDisablesSectionNavigation() {
        let fixture = makeFixture()
        #expect(!fixture.player.hasMusicSections)
        #expect(!fixture.player.canPlayPreviousSection)
        #expect(!fixture.player.canSkipToNextSection)
    }

    @available(macOS 27, iOS 27, *)
    @Test func nextSectionIsEnabledOnlyWithALaterBoundaryOrANextTrack() async {
        let fixture = makeFixture(itemCount: 1)
        #expect(!fixture.player.canSkipToNextSection)
        await play(0, in: fixture)
        // The analysis result arrives while the clock stays at the start.
        #expect(fixture.player.hasNextSectionBoundary)
        #expect(fixture.player.canSkipToNextSection)

        fixture.player.currentTime = 49.9
        #expect(fixture.player.canSkipToNextSection)
        fixture.player.currentTime = 50
        #expect(!fixture.player.canSkipToNextSection)
        fixture.player.currentTime = 10
        #expect(fixture.player.canSkipToNextSection)

        let twoTracks = makeFixture()
        await play(0, in: twoTracks)
        twoTracks.player.currentTime = 60
        #expect(twoTracks.player.canSkipToNextSection)
    }

    @available(macOS 27, iOS 27, *)
    @Test func nextSectionMovesToABoundaryJustAheadOfTheClock() async {
        let fixture = makeFixture()
        await play(0, in: fixture)
        fixture.player.currentTime = 19.9
        fixture.player.nextSection()
        #expect(fixture.audio.seekRequests.last?.time == 20)

        fixture.player.currentTime = 49.9
        fixture.player.nextSection()
        #expect(fixture.audio.seekRequests.last?.time == 50)
        #expect(fixture.player.currentItem?.id == fixture.items[0].id)
    }

    /// The audio engine seeks after a fade and reports the earlier time until then, while the clock keeps ticking.
    @available(macOS 27, iOS 27, *)
    @Test func consecutiveNextSectionsContinueFromThePendingTarget() async {
        let fixture = makeFixture()
        await play(0, in: fixture)
        fixture.audio.currentTime = 5
        fixture.player.synchronizePlaybackClock()

        fixture.player.nextSection()
        fixture.player.synchronizePlaybackClock()
        #expect(fixture.player.currentTime == 20)
        fixture.player.nextSection()
        #expect(fixture.audio.seekRequests.map(\.time) == [20, 50])
        #expect(!fixture.player.hasNextSectionBoundary)

        // Once the engine reports the target, the clock follows it again.
        fixture.audio.currentTime = 50.1
        fixture.player.synchronizePlaybackClock()
        fixture.audio.currentTime = 52
        fixture.player.synchronizePlaybackClock()
        #expect(fixture.player.currentTime == 52)
    }

    @available(macOS 27, iOS 27, *)
    @Test func consecutivePreviousSectionsContinueFromThePendingTarget() async {
        let fixture = makeFixture()
        await play(0, in: fixture)
        fixture.audio.currentTime = 30
        fixture.player.synchronizePlaybackClock()

        fixture.player.previousSection()
        fixture.player.synchronizePlaybackClock()
        fixture.player.previousSection()
        #expect(fixture.audio.seekRequests.map(\.time) == [20, 0])
    }

    @available(macOS 27, iOS 27, *)
    @Test func nextSectionSkipsTheBoundaryTheEngineReachedOnAFrameJustBeforeIt() async {
        let fixture = makeFixture()
        await play(0, in: fixture)
        fixture.player.currentTime = 5
        fixture.player.nextSection()
        fixture.audio.currentTime = 19.99998
        fixture.player.synchronizePlaybackClock()
        #expect(fixture.player.currentTime == 19.99998)

        fixture.player.nextSection()
        #expect(fixture.audio.seekRequests.map(\.time) == [20, 50])
    }

    @available(macOS 27, iOS 27, *)
    @Test func anotherSeekOrTrackReleasesThePendingSectionTarget() async {
        let fixture = makeFixture()
        await play(0, in: fixture)
        fixture.player.currentTime = 5
        fixture.player.nextSection()
        fixture.player.seek(to: 40)
        fixture.audio.currentTime = 40
        fixture.player.synchronizePlaybackClock()
        #expect(fixture.player.currentTime == 40)

        fixture.player.nextSection()
        await play(1, in: fixture)
        fixture.audio.currentTime = 3
        fixture.player.synchronizePlaybackClock()
        #expect(fixture.player.currentTime == 3)
    }
}

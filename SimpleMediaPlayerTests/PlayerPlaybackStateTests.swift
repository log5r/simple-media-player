import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct PlayerPlaybackStateTests {
    @Test func pauseAtZeroSurvivesSeekingAndEngineResetUntilResume() {
        let item = makePlaybackStateItem(id: 1, title: "One", duration: 20)
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/one.mp3")])
        fixture.player.play(item: item, in: [item])
        fixture.player.pause()

        #expect(fixture.player.currentTime == 0)
        #expect(fixture.player.isPaused)
        #expect(fixture.player.isPlaying == false)

        fixture.player.seek(to: 9)
        fixture.player.seek(to: 0)
        fixture.player.resetAudioEngine()

        #expect(fixture.player.currentTime == 0)
        #expect(fixture.player.isPaused)
        #expect(fixture.player.isPlaying == false)

        fixture.player.resume()

        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.isPlaying)

        fixture.player.pause()
        fixture.player.clearCurrentItem()

        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.player.queue.isEmpty)
    }

    @Test func stoppedPlaybackDoesNotBecomePausedWhenSeeking() {
        let item = makePlaybackStateItem(id: 1, title: "One", duration: 20)
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/one.mp3")])
        fixture.player.play(item: item, in: [item])
        fixture.player.pause()
        fixture.player.stop()
        fixture.player.seek(to: 9)
        fixture.player.pause()

        #expect(fixture.player.currentTime == 9)
        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.audio.seekRequests.last?.autoPlay == false)

        fixture.player.resume()
        fixture.audio.onFinished?()

        #expect(fixture.player.currentTime == 0)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.player.isPaused == false)
    }

    @Test func newPlaybackAndResolutionFailureClearPause() {
        let first = makePlaybackStateItem(id: 1, title: "One")
        let second = makePlaybackStateItem(id: 2, title: "Two")
        let missing = makePlaybackStateItem(id: 3, title: "Missing")
        let fixture = makePlayerFixture(urlsByID: [
            first.id: URL(fileURLWithPath: "/tmp/one.mp3"),
            second.id: URL(fileURLWithPath: "/tmp/two.mp3")
        ])
        fixture.player.play(item: first, in: [first, second, missing])
        fixture.player.pause()
        fixture.player.play(item: second, in: [first, second, missing])

        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.isPlaying)

        fixture.player.play(item: missing, in: [first, second, missing])

        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.audio.suspendCallCount == 1)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.player.queue.isEmpty)
        fixture.player.resume()
        #expect(fixture.audio.playCallCount == 2)

        fixture.player.play(item: second, in: [first, second, missing])
        fixture.player.pause()
        fixture.player.play(item: missing, in: [first, second, missing])

        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.audio.suspendCallCount == 2)
        #expect(fixture.player.currentItem == nil)
        fixture.player.resume()
        #expect(fixture.audio.playCallCount == 3)
        #expect(fixture.player.errorMessage == L10n.format("Could not open file: %@", "Missing"))
    }

    @Test func resolutionFailureClosesPreviousVideoPlayback() async {
        let movie = makePlaybackStateItem(id: 1, title: "Movie", isVideo: true, fileName: "movie.mov")
        let missing = makePlaybackStateItem(id: 2, title: "Missing")
        let fixture = makePlayerFixture(urlsByID: [movie.id: URL(fileURLWithPath: "/tmp/movie.mov")])
        fixture.player.play(item: movie, in: [movie, missing])
        await Task.yield()
        await Task.yield()
        #expect(fixture.player.isPlaying)

        fixture.player.play(item: missing, in: [movie, missing])

        #expect(fixture.player.isPlaying == false)
        #expect(fixture.player.isPaused == false)
        #expect(fixture.video.closeCallCount == 1)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.player.queue.isEmpty)
        fixture.player.resume()
        #expect(fixture.video.playCallCount == 1)
        #expect(fixture.audio.playCallCount == 0)
    }

    @Test func audioErrorClearsPauseWithoutRelyingOnPlaybackPosition() {
        let item = makePlaybackStateItem(id: 1, title: "One", duration: 20)
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/one.mp3")])
        fixture.player.play(item: item, in: [item])
        fixture.player.seek(to: 9)
        fixture.player.pause()
        fixture.audio.onError?("decode failed")

        #expect(fixture.player.currentTime == 9)
        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.player.errorMessage == "decode failed")
    }

    @Test func videoLoadingClearsAudioPause() async {
        let audio = makePlaybackStateItem(id: 1, title: "Audio")
        let movie = makePlaybackStateItem(id: 2, title: "Movie", isVideo: true)
        let fixture = makePlayerFixture(urlsByID: [
            audio.id: URL(fileURLWithPath: "/tmp/audio.mp3"), movie.id: URL(fileURLWithPath: "/tmp/movie.mov")
        ])
        fixture.player.play(item: audio, in: [audio, movie])
        fixture.player.pause()
        #expect(fixture.player.isPaused)

        fixture.player.play(item: movie, in: [movie])
        #expect(fixture.player.isPaused == false)
        await Task.yield()
        await Task.yield()

        #expect(fixture.player.isPlaying)
        #expect(fixture.player.isPaused == false)
    }

    @Test func videoPauseAtZeroSurvivesSeekingUntilResumeOrStop() async {
        let movie = makePlaybackStateItem(id: 1, title: "Movie", duration: 20, isVideo: true)
        let fixture = makePlayerFixture(urlsByID: [movie.id: URL(fileURLWithPath: "/tmp/movie.mov")])
        fixture.player.play(item: movie, in: [movie])
        await Task.yield()
        await Task.yield()

        fixture.player.pause()
        fixture.player.seek(to: 0)
        #expect(fixture.player.currentTime == 0)
        #expect(fixture.player.isPaused)

        fixture.player.resume()
        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.isPlaying)

        fixture.player.pause()
        fixture.player.stop()
        #expect(fixture.player.isPaused == false)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.video.closeCallCount == 1)
    }
}

@MainActor
private func makePlaybackStateItem(
    id: Int,
    title: String,
    duration: TimeInterval = 30,
    isVideo: Bool = false,
    fileName: String? = nil
) -> MediaItem {
    MediaItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", id))")!,
        title: title, duration: duration, isVideo: isVideo, bookmarkData: Data([1, 2, 3]),
        fileName: fileName ?? "\(title).mp3"
    )
}

import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct PlayerPlaybackGenerationTests {
    @Test func reloadingTheSameItemInvalidatesAnEarlierSeekTarget() {
        let item = makeItem(title: "Same item")
        let url = URL(fileURLWithPath: "/tmp/generation-audio.wav")
        let fixture = makePlayerFixture(urlsByID: [item.id: url])
        fixture.player.play(item: item, in: [item])
        let target = captureSeekTarget(from: fixture.player)
        fixture.player.seek(to: 12)

        fixture.player.play(item: item, in: [item])

        #expect(fixture.player.currentItem?.id == target.itemID)
        #expect(fixture.player.currentTime == 0)
        #expect(fixture.audio.loadedURLs == [url, url])
        #expect(!target.isValid(
            itemID: fixture.player.currentItem?.id, generation: fixture.player.playbackGeneration
        ))
    }

    @Test(arguments: PlaybackGenerationInvalidation.allCases)
    func playbackInvalidationRejectsAnEarlierSeekTarget(_ invalidation: PlaybackGenerationInvalidation) {
        let item = makeItem(title: "Before invalidation")
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/generation-audio.wav")])
        fixture.player.play(item: item, in: [item])
        let target = captureSeekTarget(from: fixture.player)

        switch invalidation {
        case .stop:
            fixture.player.stop()
        case .clear:
            fixture.player.clearCurrentItem()
        case .engineReset:
            fixture.player.resetAudioEngine()
        case .decodeFailure:
            fixture.audio.onError?("decode failed")
        case .resolutionFailure:
            fixture.player.play(item: makeItem(title: "Missing"), in: [])
        }

        #expect(fixture.player.playbackGeneration != target.generation)
        #expect(!target.isValid(
            itemID: fixture.player.currentItem?.id, generation: fixture.player.playbackGeneration
        ))
    }

    @Test func pauseResumeAndSeekingRetainThePlaybackGeneration() {
        let item = makeItem(title: "Stable playback")
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/generation-audio.wav")])
        fixture.player.play(item: item, in: [item])
        let target = captureSeekTarget(from: fixture.player)

        fixture.player.pause()
        fixture.player.seek(to: 12)
        fixture.player.resume()
        fixture.player.setVolume(0.5)
        fixture.player.setPitchSemitones(2)
        fixture.player.setPlaybackRate(1.25)

        #expect(fixture.player.isPlaying)
        #expect(fixture.audio.loadedURLs.count == 1)
        #expect(fixture.audio.resetEngineCallCount == 0)
        #expect(fixture.player.currentTime == 12)
        #expect(fixture.player.playbackGeneration == target.generation)
        #expect(target.isValid(
            itemID: fixture.player.currentItem?.id, generation: fixture.player.playbackGeneration
        ))
    }

    @Test func stoppingVideoInvalidatesItsSeekTarget() async {
        let item = makeItem(title: "Video", isVideo: true)
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/generation-video.mov")])
        fixture.player.play(item: item, in: [item])
        await Task.yield()
        await Task.yield()
        let target = captureSeekTarget(from: fixture.player)

        fixture.player.stop()

        #expect(fixture.video.closeCallCount == 1)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.player.playbackGeneration != target.generation)
        #expect(!target.isValid(
            itemID: fixture.player.currentItem?.id, generation: fixture.player.playbackGeneration
        ))
    }

    @Test func resettingTheAudioEngineWhileVideoIsLoadingDoesNotDiscardItsCompletion() async {
        let item = makeItem(title: "Loading video", isVideo: true)
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/loading-video.mov")])
        fixture.player.play(item: item, in: [item])
        let generation = fixture.player.playbackGeneration

        fixture.player.resetAudioEngine()
        for _ in 0..<20 {
            await Task.yield()
            if fixture.video.playCallCount > 0 { break }
        }

        #expect(fixture.audio.resetEngineCallCount == 1)
        #expect(fixture.video.loadedURLs.count == 1)
        #expect(fixture.video.playCallCount == 1)
        #expect(fixture.player.isPlaying)
        #expect(fixture.player.playbackGeneration == generation)
    }

    private func captureSeekTarget(from player: PlayerViewModel) -> PlaybackSeekTarget {
        PlaybackSeekTarget(itemID: player.currentItem?.id, generation: player.playbackGeneration)
    }

    private func makeItem(title: String, isVideo: Bool = false) -> MediaItem {
        MediaItem(title: title, duration: 30, isVideo: isVideo, bookmarkData: Data([1]), fileName: title)
    }
}

nonisolated enum PlaybackGenerationInvalidation: CaseIterable {
    case stop
    case clear
    case engineReset
    case decodeFailure
    case resolutionFailure
}

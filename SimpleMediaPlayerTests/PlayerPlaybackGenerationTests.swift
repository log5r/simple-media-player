import AVFoundation
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

    @Test func delayedAudioFailureDoesNotInvalidateTheCurrentVideoLoad() async {
        let audioItem = makeItem(title: "Previous audio")
        let videoItem = makeItem(title: "Current video", isVideo: true)
        let videoURL = URL(fileURLWithPath: "/tmp/current-video.mov")
        let resolver = FakeMediaURLResolver(urlsByID: [
            audioItem.id: URL(fileURLWithPath: "/tmp/previous-audio.wav"), videoItem.id: videoURL
        ])
        let audio = FakeAudioEngine()
        let video = DelayedVideoLoadService()
        let player = PlayerViewModel(
            libraryService: resolver, audioEngine: audio, videoService: video, startsClock: false
        )
        player.play(item: audioItem, in: [audioItem, videoItem])
        player.play(item: videoItem, in: [audioItem, videoItem])
        await video.waitUntilLoading()
        let generation = player.playbackGeneration

        audio.onError?("Previous audio engine failed")

        #expect(video.loadedURL == videoURL)
        #expect(video.playCallCount == 0)
        #expect(player.playbackGeneration == generation)
        #expect(player.currentItem?.id == videoItem.id)
        #expect(player.errorMessage == nil)
        video.completeLoading()
        for _ in 0..<20 {
            await Task.yield()
            if video.playCallCount > 0 { break }
        }

        #expect(video.playCallCount == 1)
        #expect(player.isPlaying)
        #expect(player.playbackGeneration == generation)
        audio.onError?("Another delayed audio engine failure")
        #expect(player.isPlaying)
        #expect(player.errorMessage == nil)
        #expect(player.playbackGeneration == generation)
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

@MainActor
private final class DelayedVideoLoadService: VideoPlaybackControlling {
    let player = AVPlayer()
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 30
    var onFinished: (() -> Void)?
    var onFormatLoaded: (@MainActor (MediaFormatInfo) -> Void)?
    private(set) var loadedURL: URL?
    private(set) var playCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, Never>?
    private var loadStarted: CheckedContinuation<Void, Never>?

    func load(url: URL) async {
        loadedURL = url
        await withCheckedContinuation { continuation in
            pendingLoad = continuation
            loadStarted?.resume()
            loadStarted = nil
        }
    }

    func waitUntilLoading() async {
        guard pendingLoad == nil else { return }
        await withCheckedContinuation { loadStarted = $0 }
    }

    func completeLoading() {
        pendingLoad?.resume()
        pendingLoad = nil
    }

    func play() { playCallCount += 1 }
    func pause() {}
    func setVolume(_ volume: Float) {}
    func setEqualizer(_ settings: EqualizerSettings) {}
    func stop() {}
    func close() {}
    func seek(to time: TimeInterval) {}
}

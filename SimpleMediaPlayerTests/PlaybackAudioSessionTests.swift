import Foundation
import Observation
import Synchronization
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackAudioSessionTests {
    @Test(arguments: [false, true])
    func playbackWaitsForActivationWithoutBlockingTheMainActor(isVideo: Bool) async throws {
        let fixture = AudioSessionPlayerFixture(isVideo: isVideo)
        #expect(fixture.activation.calls == 0)
        fixture.play()
        let pending = try #require(fixture.player.pendingPlaybackStart)
        defer { fixture.activation.finish() }
        try await fixture.activation.waitUntilStarted()

        #expect(!fixture.player.isPlaying)
        #expect(fixture.playCount == 0)
        #expect(fixture.player.canPause)
        #expect(!fixture.player.canResume)
        let heartbeat = Task { @MainActor in 1 }
        #expect(await heartbeat.value == 1)
        let completionChanges = observePlaybackCapabilities(fixture.player)
        fixture.activation.finish()
        await pending.value

        #expect(completionChanges.count > 0)
        #expect(fixture.playCount == 1)
        #expect(fixture.player.isPlaying)
        #expect(fixture.activation.calls == 1)
        #expect(fixture.session.isReady)
    }

    @Test(arguments: [false, true], [PendingPlaybackAction.pause, .stop, .clear])
    func invalidatedPlaybackCannotStartAfterActivation(isVideo: Bool, action: PendingPlaybackAction) async throws {
        let fixture = AudioSessionPlayerFixture(isVideo: isVideo)
        fixture.play()
        let pending = try #require(fixture.player.pendingPlaybackStart)
        defer { fixture.activation.finish() }
        try await fixture.activation.waitUntilStarted()
        let cancellationChanges = observePlaybackCapabilities(fixture.player)

        switch action {
        case .pause: fixture.player.pause()
        case .stop: fixture.player.stop()
        case .clear: fixture.player.clearCurrentItem()
        }
        fixture.activation.finish()
        await pending.value

        #expect(cancellationChanges.count > 0)
        #expect(fixture.playCount == 0)
        #expect(!fixture.player.isPlaying)
        #expect(fixture.player.isPaused == (action == .pause))
    }

    @Test(arguments: [false, true])
    func pauseAndResumeShareActivationButStartOnlyTheCurrentRequest(isVideo: Bool) async throws {
        let fixture = AudioSessionPlayerFixture(isVideo: isVideo)
        fixture.play()
        let old = try #require(fixture.player.pendingPlaybackStart)
        defer { fixture.activation.finish() }
        try await fixture.activation.waitUntilStarted()
        fixture.player.pause()
        fixture.player.resume()
        let resumed = try #require(fixture.player.pendingPlaybackStart)
        fixture.activation.finish()
        await old.value
        await resumed.value

        #expect(fixture.playCount == 1)
        #expect(fixture.activation.calls == 1)
        #expect(fixture.player.isPlaying)
        #expect(!fixture.player.isPaused)
    }

    @Test func switchingTracksDuringActivationStartsOnlyTheLatestTrack() async throws {
        let fixture = AudioSessionPlayerFixture()
        fixture.play()
        let old = try #require(fixture.player.pendingPlaybackStart)
        defer { fixture.activation.finish() }
        try await fixture.activation.waitUntilStarted()
        let next = MediaItem(title: "Next", duration: 2, isVideo: false, bookmarkData: Data(), fileName: "next.wav")
        fixture.resolver.urlsByID[next.id] = URL(fileURLWithPath: "/tmp/next.wav")
        fixture.player.play(item: next, in: [fixture.item, next])
        let latest = try #require(fixture.player.pendingPlaybackStart)
        fixture.activation.finish()
        await old.value
        await latest.value

        #expect(fixture.player.currentItem?.id == next.id)
        #expect(fixture.audio.loadedURLs.count == 2)
        #expect(fixture.playCount == 1)
        #expect(fixture.activation.calls == 1)
    }

    @Test func activationFailureCanBeRetried() async throws {
        let fixture = AudioSessionPlayerFixture()
        fixture.play()
        let failed = try #require(fixture.player.pendingPlaybackStart)
        defer { fixture.activation.finish() }
        try await fixture.activation.waitUntilStarted()
        let failureChanges = observePlaybackCapabilities(fixture.player)
        fixture.activation.finish(throwing: CocoaError(.fileReadUnknown))
        await failed.value
        #expect(failureChanges.count > 0)
        #expect(fixture.player.errorMessage != nil)
        #expect(!fixture.session.isReady)
        #expect(!fixture.player.canPause)
        #expect(fixture.player.canResume)
        #expect(fixture.playCount == 0)

        fixture.player.resume()
        let retry = try #require(fixture.player.pendingPlaybackStart)
        try await fixture.activation.waitUntilStarted(calls: 2)
        fixture.activation.finish()
        await retry.value
        #expect(fixture.playCount == 1)
        #expect(fixture.session.isReady)
    }

    @Test func clearedTrackDoesNotReceiveALateActivationFailure() async throws {
        let fixture = AudioSessionPlayerFixture()
        fixture.play()
        let pending = try #require(fixture.player.pendingPlaybackStart)
        defer { fixture.activation.finish() }
        try await fixture.activation.waitUntilStarted()
        fixture.player.clearCurrentItem()
        fixture.activation.finish(throwing: CocoaError(.fileReadUnknown))
        await pending.value
        #expect(fixture.player.errorMessage == nil)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.playCount == 0)
    }

    @Test func categoryConfigurationRunsOffMainAndPrecedesActivation() async throws {
        let probe = AudioCategoryProbe()
        try await PlaybackAudioSession.configureAndActivate {
            probe.record()
        } activate: {
            #expect(probe.configured)
            #expect(!probe.wasMainThread)
            return true
        }
        #expect(probe.configured)
    }

    @Test func failedConfigurationDoesNotActivateTheSession() async {
        await #expect(throws: CocoaError.self) {
            try await PlaybackAudioSession.configureAndActivate {
                throw CocoaError(.fileReadUnknown)
            } activate: {
                Issue.record("Activation must not follow a failed category configuration.")
                return true
            }
        }
    }

    @Test func unsuccessfulActivationIsAnError() async {
        await #expect(throws: CocoaError.self) {
            try await PlaybackAudioSession.configureAndActivate(configure: {}, activate: { false })
        }
    }
}

nonisolated enum PendingPlaybackAction: CaseIterable {
    case pause, stop, clear
}

@MainActor
private struct AudioSessionPlayerFixture {
    let item: MediaItem
    let player: PlayerViewModel
    let audio = FakeAudioEngine()
    let video = FakeVideoService()
    let resolver: FakeMediaURLResolver
    let activation = AudioSessionActivationProbe()
    let session: PlaybackAudioSession

    init(isVideo: Bool = false) {
        item = MediaItem(title: "Pending", duration: 2, isVideo: isVideo, bookmarkData: Data(), fileName: "pending.wav")
        resolver = FakeMediaURLResolver(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/pending.wav")])
        let activation = activation
        session = PlaybackAudioSession { try await activation.run() }
        player = PlayerViewModel(
            libraryService: resolver, audioEngine: audio, videoService: video, startsClock: false,
            musicAnalysis: MusicAnalysisController(analyze: { _ in throw CancellationError() }),
            audioSession: session
        )
    }

    var playCount: Int { audio.playCallCount + video.playCallCount }
    func play() { player.play(item: item, in: [item]) }
}

@MainActor
private func observePlaybackCapabilities(_ player: PlayerViewModel) -> PlaybackCapabilityChanges {
    let changes = PlaybackCapabilityChanges()
    withObservationTracking {
        _ = player.canPause
        _ = player.canResume
    } onChange: {
        changes.record()
    }
    return changes
}

private final class PlaybackCapabilityChanges: Sendable {
    private let storage = Mutex(0)
    var count: Int { storage.withLock { $0 } }
    func record() { storage.withLock { $0 += 1 } }
}

@MainActor
private final class AudioSessionActivationProbe {
    private(set) var calls = 0
    private var pending: CheckedContinuation<Void, any Error>?

    func run() async throws {
        calls += 1
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func waitUntilStarted(calls expected: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while calls < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(calls == expected)
    }

    func finish(throwing error: (any Error)? = nil) {
        let continuation = pending
        pending = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}

private nonisolated final class AudioCategoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var state = (configured: false, wasMainThread: false)
    var configured: Bool { lock.withLock { state.configured } }
    var wasMainThread: Bool { lock.withLock { state.wasMainThread } }
    func record() { lock.withLock { state = (true, Thread.isMainThread) } }
}

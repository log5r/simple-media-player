import AVFoundation
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct SpectrumAnalyzerSuppressionTests {
    @Test(arguments: VisualizerResponseMode.allCases)
    func disablingDropsScheduledChunksAndIgnoresLaterTaps(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        // One second of input schedules chunks that would arrive after the analyzer is disabled.
        analyzer.analyze(try toneBuffer(frameCount: 44_100), currentTime: 1, isPlaying: true)
        try await waitUntil { frames.contains { $0.isPlaying && !$0.isSilent } }
        analyzer.setAnalysisEnabled(false)
        let count = frames.count

        for time in 2..<40 {
            analyzer.analyze(try toneBuffer(), currentTime: TimeInterval(time), isPlaying: true)
        }
        // A stop while disabled must not start the decay animation either.
        analyzer.setPlaybackActive(false, currentTime: 50)
        try await Task.sleep(for: .milliseconds(300))
        #expect(frames.count == count)
    }

    @Test(arguments: [true, false])
    func enablingPublishesSilenceOnceThenFollowsNewInput(isPlaying: Bool) async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setPlaybackActive(true, currentTime: 0)
        analyzer.analyze(try toneBuffer(), currentTime: 1, isPlaying: true)
        try await waitUntil { frames.contains { !$0.isSilent } }
        analyzer.setAnalysisEnabled(false)
        if isPlaying == false { analyzer.setPlaybackActive(false, currentTime: 2) }
        try await Task.sleep(for: .milliseconds(100))
        let disabledAt = frames.count

        analyzer.setAnalysisEnabled(true)
        try await waitUntil { frames.count > disabledAt }
        let resumed = try #require(frames.last)
        #expect(resumed.isSilent)
        #expect(resumed.isPlaying == isPlaying)
        guard isPlaying else {
            try await Task.sleep(for: .milliseconds(200))
            #expect(frames.count == disabledAt + 1)
            return
        }
        analyzer.analyze(try toneBuffer(), currentTime: 20, isPlaying: true)
        try await waitUntil { frames.last.map { !$0.isSilent && $0.currentTime >= 20 } == true }
        #expect(frames.dropFirst(disabledAt + 1).allSatisfy { $0.isPlaying && $0.currentTime >= 20 })
    }

    @Test(arguments: [VisualizerResponseMode.normal, .fast])
    func rapidDisableAndEnableDiscardsEveryOlderResult(mode: VisualizerResponseMode) async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setResponseMode(mode)
        analyzer.setPlaybackActive(true, currentTime: 0)
        analyzer.analyze(try toneBuffer(frameCount: 44_100), currentTime: 1, isPlaying: true)
        try await waitUntil { frames.contains { $0.isPlaying } }
        analyzer.setAnalysisEnabled(false)
        analyzer.setAnalysisEnabled(true)
        let enabledAt = frames.count
        analyzer.analyze(try toneBuffer(), currentTime: 50, isPlaying: true)
        try await waitUntil { frames.last.map { $0.currentTime >= 50 && !$0.isSilent } == true }
        try await Task.sleep(for: .milliseconds(300))

        // Only the silent frame of the enable and frames of the new input remain.
        let later = frames.dropFirst(enabledAt)
        #expect(later.allSatisfy { $0.isSilent || $0.currentTime >= 50 })
        #expect(later.filter { $0.currentTime < 50 }.count <= 1)
    }

    @Test func bandCountChangedWhileDisabledIsPublishedOnEnable() async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setAnalysisEnabled(false)
        analyzer.setBandCount(32)
        try await Task.sleep(for: .milliseconds(150))
        #expect(frames.isEmpty)
        analyzer.setAnalysisEnabled(true)
        try await waitUntil { frames.isEmpty == false }
        #expect(frames.count == 1)
        #expect(frames.last?.bandsL.count == 32)
        #expect(frames.last?.isSilent == true)
    }

    @Test func videoTapGenerationFollowsEnabledState() async throws {
        let analyzer = SpectrumAnalyzer()
        var frames: [AudioFrameData] = []
        analyzer.onFrame = { frames.append($0) }
        analyzer.setPlaybackActive(true, currentTime: 0)
        let previous = analyzer.realtimeVideoGeneration
        #expect(previous != 0)

        // The tap stamps generation 0 while disabled, which the sample ring rejects before copying.
        analyzer.setAnalysisEnabled(false)
        #expect(analyzer.realtimeVideoGeneration == 0)
        analyzer.setPlaybackActive(true, currentTime: 1)
        #expect(analyzer.realtimeVideoGeneration == 0)

        analyzer.setAnalysisEnabled(true)
        let current = analyzer.realtimeVideoGeneration
        #expect(current != 0 && current != previous)
        try await waitUntil { frames.count == 1 }

        // Samples captured before the suspension are stale.
        analyzer.analyzeVideoSamples(videoBatch(time: 1, generation: previous)) { true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(frames.count == 1)

        analyzer.analyzeVideoSamples(videoBatch(time: 2, generation: current)) { true }
        try await waitUntil { frames.last.map { !$0.isSilent && $0.currentTime >= 2 } == true }
    }

    private func videoBatch(time: TimeInterval, generation: Int) -> VideoAudioSampleRing.Batch {
        let samples = (0..<4_800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.4 }
        return .init(
            left: samples, right: samples, sampleRate: 48_000, time: time,
            analysisGeneration: generation, sourceEpoch: 3, startsStream: true
        )
    }
}

@MainActor
struct PlayerVisualizationSuppressionTests {
    @Test func visualizerIdleChangesOnlyOnTransitions() {
        let fixture = SuppressionFixture()
        let player = fixture.player
        #expect(player.isVisualizerIdle)

        let started = observe { _ = player.isVisualizerIdle }
        fixture.play()
        #expect(started.count == 1)
        #expect(player.isVisualizerIdle == false)

        let playing = observe { _ = player.isVisualizerIdle }
        for level in 1...20 { fixture.deliver(loudFrame(level: Float(level) / 20, isPlaying: true)) }
        fixture.deliver(.silent(isPlaying: true))
        fixture.deliver(loudFrame(level: 0.5, isPlaying: true))
        // A paused player still draws the decay until the frames are silent.
        player.pause()
        for level in stride(from: Float(0.5), to: 0, by: -0.1) {
            fixture.deliver(loudFrame(level: level, isPlaying: false))
        }
        #expect(playing.count == 0)
        #expect(player.isVisualizerIdle == false)

        fixture.deliver(.silent())
        #expect(playing.count == 1)
        #expect(player.isVisualizerIdle)
        let idle = observe { _ = player.isVisualizerIdle }
        fixture.deliver(.silent())
        fixture.deliver(.silent())
        #expect(idle.count == 0)
    }

    @Test func visualizerHostBodyDoesNotObserveAnalysisFrames() {
        let fixture = SuppressionFixture()
        let player = fixture.player
        fixture.play()
        let playing = observe {
            _ = VisualizerHostView(player: player, palette: palette).body
        }
        for level in 1...10 { fixture.deliver(loudFrame(level: Float(level) / 10, isPlaying: true)) }
        fixture.deliver(.silent(isPlaying: true))
        fixture.deliver(loudFrame(level: 0.8, isPlaying: true))
        #expect(playing.count == 0)

        // After a pause the analyzer publishes decay frames at the drawing rate until they are silent.
        player.pause()
        let decaying = observe {
            _ = VisualizerHostView(player: player, palette: palette).body
        }
        for level in stride(from: Float(0.8), to: 0, by: -0.1) {
            fixture.deliver(loudFrame(level: level, isPlaying: false))
        }
        #expect(decaying.count == 0)
        // Only reaching silence pauses the timeline, which re-evaluates the host once.
        fixture.deliver(.silent())
        #expect(decaying.count == 1)
    }

    @Test func analysisRunsOnlyWhileAVisibleConsumerIsInTheForeground() async throws {
        let fixture = SuppressionFixture()
        let player = fixture.player
        #expect(player.isVisualizationSuspended)
        let consumer = UUID()
        let other = UUID()
        player.addVisualizationConsumer(consumer)
        player.addVisualizationConsumer(consumer)
        player.addVisualizationConsumer(other)
        #expect(player.isVisualizationSuspended == false)
        fixture.play()
        fixture.analyzer.analyze(try toneBuffer(), currentTime: 1, isPlaying: true)
        try await waitUntil { player.audioFrame.isSilent == false }

        player.setInBackground(true)
        #expect(player.isVisualizationSuspended)
        // The last frame is dropped at once, so the display cannot return to frozen bars.
        #expect(player.audioFrame.isSilent)
        #expect(player.audioFrame.isPlaying)
        #expect(player.spectrumFrameRate == 0)
        for time in 2..<20 {
            fixture.analyzer.analyze(try toneBuffer(), currentTime: TimeInterval(time), isPlaying: true)
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(player.audioFrame.isSilent)

        player.setInBackground(false)
        #expect(player.isVisualizationSuspended == false)
        fixture.analyzer.analyze(try toneBuffer(), currentTime: 30, isPlaying: true)
        try await waitUntil { player.audioFrame.isSilent == false && player.audioFrame.currentTime >= 30 }

        // Registering the same view twice still needs only one removal.
        player.removeVisualizationConsumer(consumer)
        #expect(player.isVisualizationSuspended == false)
        player.removeVisualizationConsumer(other)
        #expect(player.isVisualizationSuspended)
        #expect(player.audioFrame.isSilent)
        player.removeVisualizationConsumer(other)
        player.addVisualizationConsumer(other)
        #expect(player.isVisualizationSuspended == false)
    }

    @Test func backgroundLowersThePlaybackClockUntilTheForegroundReturns() {
        let fixture = SuppressionFixture(startsClock: true)
        let player = fixture.player
        fixture.play()
        #expect(player.playbackClockInterval == 1.0 / 30)

        player.setInBackground(true)
        #expect(player.playbackClockInterval == 1)
        fixture.audio.currentTime = 12.5
        player.setInBackground(false)
        #expect(player.playbackClockInterval == 1.0 / 30)
        #expect(player.currentTime == 12.5)

        player.setInBackground(true)
        player.pause()
        #expect(player.playbackClockInterval == nil)
        player.resume()
        #expect(player.playbackClockInterval == 1)
        player.setInBackground(false)
        #expect(player.playbackClockInterval == 1.0 / 30)
        player.pause()
    }

    private var palette: LEDDisplayPalette {
        .resolved(
            styleRaw: "dark", darkForegroundHex: AppSettingsDefault.ledColorHex,
            backlitForegroundHex: AppSettingsDefault.ledBacklitForegroundColorHex,
            backlightHex: AppSettingsDefault.ledBacklightColorHex
        )
    }

    private func loudFrame(level: Float, isPlaying: Bool) -> AudioFrameData {
        var frame = AudioFrameData.silent(isPlaying: isPlaying)
        frame.bandsL[0] = level
        frame.rmsR = level
        return frame
    }

    private func observe(_ read: () -> Void) -> ObservationChangeCount {
        let changes = ObservationChangeCount()
        withObservationTracking(read) { changes.record() }
        return changes
    }
}

@MainActor
private struct SuppressionFixture {
    let analyzer = SpectrumAnalyzer()
    let audio = FakeAudioEngine()
    let player: PlayerViewModel
    let item = MediaItem(
        title: "Visualizer", duration: 30, isVideo: false, bookmarkData: Data([1]), fileName: "visualizer.mp3"
    )

    init(startsClock: Bool = false) {
        player = PlayerViewModel(
            libraryService: FakeMediaURLResolver(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/visualizer.mp3")]),
            analyzer: analyzer,
            audioEngine: audio,
            videoService: FakeVideoService(),
            startsClock: startsClock
        )
    }

    func play() {
        player.play(item: item, in: [item])
    }

    /// Delivers a frame as the analyzer does, on the main actor.
    func deliver(_ frame: AudioFrameData) {
        analyzer.onFrame?(frame)
    }
}

private final class ObservationChangeCount: Sendable {
    private let storage = Mutex(0)
    var count: Int { storage.withLock { $0 } }
    func record() { storage.withLock { $0 += 1 } }
}

private func toneBuffer(frameCount: AVAudioFrameCount = 4_410) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let channels = try #require(buffer.floatChannelData)
    for index in 0..<Int(frameCount) {
        let sample = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.4
        channels[0][index] = sample
        channels[1][index] = sample * 0.5
    }
    return buffer
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while condition() == false, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
}

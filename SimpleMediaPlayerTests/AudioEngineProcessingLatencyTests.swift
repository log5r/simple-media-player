import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.serialized)
struct AudioEngineProcessingLatencyTests {
    @Test(arguments: [Float(0.5), 1, 2])
    func seekAndPauseResumeClockIncludesRealtimeTimePitchLatency(rate: Float) async throws {
        let fixture = try await RealtimeClockFixture()
        defer { fixture.remove() }
        fixture.service.setPlaybackRate(rate)
        fixture.service.seek(to: 1, autoPlay: true)
        try #require(await fixture.service.isEngineRunning)

        // Offline rendering reports zero TimePitch latency and cannot reproduce
        // this bug. Realtime manual rendering uses the live DSP without a device.
        let timePitch = try #require(fixture.probe.engine.attachedNodes.compactMap {
            $0 as? AVAudioUnitTimePitch
        }.first)
        try #require(timePitch.latency > 0)
        #expect(timePitch.bypass == (rate == 1))
        let elapsed = (1 - fixture.probe.processingLatency) * Double(rate)
        try #require(elapsed > 0)
        try await fixture.renderSecond(expecting: 1 + elapsed)

        fixture.service.pause()
        _ = await fixture.service.isEngineRunning
        let paused = fixture.service.currentTime
        #expect(abs(paused - (1 + elapsed)) < fixture.tolerance)
        fixture.service.play()
        try #require(await fixture.service.isEngineRunning)
        try await fixture.renderSecond(expecting: paused + elapsed)

        fixture.service.seek(to: 3, autoPlay: true)
        try #require(await fixture.service.isEngineRunning)
        try await fixture.renderSecond(expecting: 3 + elapsed)
        #expect(fixture.finishCount == 0)
        #expect(fixture.errors.isEmpty)
    }

    @Test func seekRejectsPendingAndLateTapBuffers() async throws {
        let fixture = try await RealtimeClockFixture()
        defer { fixture.remove() }
        let service = fixture.service
        try await fixture.startVisualization()
        let oldTapTime = AVAudioTime(hostTime: mach_absolute_time())
        let oldRender = try #require(service.outputProtection.outputNode.lastRenderTime)
        try #require(oldRender.isSampleTimeValid)
        let oldSampleTime = AVAudioTime(sampleTime: oldRender.sampleTime, atRate: oldRender.sampleRate)
        #expect(fixture.generation(at: oldTapTime) != 0)

        // Hold the engine on the first segment while the UI has already moved to the seek target.
        service.controlQueue.suspend()
        service.seek(to: 3, autoPlay: true)
        service.analyzer.setPlaybackActive(true, currentTime: 3)
        let duringSeek = fixture.generation(at: oldTapTime)
        service.controlQueue.resume()
        #expect(duringSeek == 0)
        try #require(await service.isEngineRunning)
        #expect(fixture.generation(at: oldTapTime) == 0)
        #expect(fixture.generation(at: oldSampleTime) == 0)
        let buffered = AVAudioTime(
            hostTime: mach_absolute_time(), sampleTime: oldRender.sampleTime, atRate: oldRender.sampleRate
        )
        #expect(fixture.generation(at: buffered) == 0)
        let seekBoundary = fixture.frames.count
        try fixture.probe.renderSecond()
        try await fixture.waitUntil { fixture.frames.count > seekBoundary }
        #expect(fixture.frames.dropFirst(seekBoundary).allSatisfy { $0.currentTime >= 3 && $0.isPlaying })
    }

    @Test func queuedStopAndTrackSwitchRejectOldTapBuffers() async throws {
        let fixture = try await RealtimeClockFixture()
        defer { fixture.remove() }
        let service = fixture.service
        let replacement = try PitchProcessingSource(
            sampleRate: 48_000, channelCount: 1, samples: [Float](repeating: 0, count: 144_000)
        )
        defer { replacement.remove() }
        try await fixture.startVisualization(at: 3)
        let oldTapTime = AVAudioTime(hostTime: mach_absolute_time())
        // A stop and a track switch can both be queued before the engine services the stop.
        service.controlQueue.suspend()
        service.stop(reset: true)
        let duringStop = fixture.generation(at: oldTapTime)
        service.load(url: replacement.url)
        service.play()
        service.analyzer.setPlaybackActive(true, currentTime: 0)
        let duringSwitch = fixture.generation(at: oldTapTime)
        service.controlQueue.resume()
        #expect(duringStop == 0)
        #expect(duringSwitch == 0)
        try await fixture.waitUntil { fixture.generation(at: AVAudioTime(hostTime: mach_absolute_time())) != 0 }
        #expect(fixture.generation(at: oldTapTime) == 0)
        let switchBoundary = fixture.frames.count
        try fixture.probe.renderSecond()
        try await fixture.waitUntil { fixture.frames.count > switchBoundary }
        #expect(fixture.frames.dropFirst(switchBoundary).allSatisfy { $0.isPlaying && $0.currentTime < 3 })
    }
}

@MainActor
private final class RealtimeClockFixture {
    let source: PitchProcessingSource
    let probe: RealtimeClockProbe
    let service: AudioEngineService
    let tolerance = 4.0 / 48_000
    private var loaded = false
    private(set) var finishCount = 0
    private(set) var errors: [String] = []
    private(set) var frames: [AudioFrameData] = []

    init() async throws {
        source = try PitchProcessingSource(
            sampleRate: 48_000, channelCount: 1,
            samples: [Float](repeating: 0, count: 480_000)
        )
        probe = try RealtimeClockProbe()
        let probe = probe
        service = AudioEngineService(
            analyzer: SpectrumAnalyzer(),
            openReadableFile: { ExtendedAudioCache.ReadableFile(url: $0) },
            waitForFadeStep: { _ in },
            engineFactory: { probe.engine },
            preparePlayer: { player, _ in player.prepare(withFrameCount: 480_000) }
        )
        service.onFormatLoaded = { [weak self] _, _ in self?.loaded = true }
        service.onFinished = { [weak self] in self?.finishCount += 1 }
        service.onError = { [weak self] in self?.errors.append($0) }
        service.load(url: source.url)
        try await waitUntil { self.loaded }
    }

    func renderSecond(expecting expected: TimeInterval) async throws {
        try probe.renderSecond()
        // Taps are delivered asynchronously in larger batches than the requested
        // render blocks. Wait for the clock to reach the final batch before comparing.
        try await waitUntil { self.service.currentTime >= expected - self.tolerance }
        #expect(abs(service.currentTime - expected) < tolerance)
    }

    func startVisualization(at time: TimeInterval = 0) async throws {
        service.analyzer.onFrame = { [weak self] in self?.frames.append($0) }
        service.seek(to: time, autoPlay: true)
        try #require(await service.isEngineRunning)
        service.analyzer.setPlaybackActive(true, currentTime: time)
        try probe.renderSecond()
        try await waitUntil { self.frames.contains { $0.isPlaying && $0.currentTime >= time } }
    }

    func generation(at time: AVAudioTime) -> Int {
        service.advanceDisplayClock(byFrames: 0, sampleRate: 48_000, capturedAt: time).analysisGeneration
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    func remove() {
        service.suspend()
        source.remove()
    }
}

// Control operations are drained through isEngineRunning before the test drives
// the render block. No hardware or wall-clock playback advances this engine.
nonisolated private final class RealtimeClockProbe: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let output: AVAudioPCMBuffer

    var processingLatency: TimeInterval {
        engine.attachedNodes.reduce(0) { $0 + $1.latency }
    }

    init() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
    }

    func renderSecond() throws {
        let render = engine.manualRenderingBlock
        var remaining = 48_000
        var attempts = 0
        while remaining > 0 {
            attempts += 1
            try #require(attempts < 1_000)
            let frames = AVAudioFrameCount(min(remaining, 512))
            output.frameLength = frames
            var error: OSStatus = noErr
            let status = render(frames, output.mutableAudioBufferList, &error)
            if status == .cannotDoInCurrentContext { continue }
            try #require(status == .success && error == noErr)
            remaining -= Int(frames)
        }
    }
}

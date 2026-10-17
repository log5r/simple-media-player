import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.serialized)
struct AudioEngineConfigurationRecoveryTests {
    @Test func configurationChangeResumesFromTheSavedPosition() async throws {
        let fixture = try await ConfigurationRecoveryFixture()
        defer { fixture.remove() }
        let savedTime = fixture.service.currentTime
        _ = try await fixture.beginRecovery()
        fixture.probe.releasePreparation()

        #expect(await fixture.service.isEngineRunning)
        try await fixture.waitUntil { fixture.service.currentTime > savedTime + 0.05 }
        #expect(fixture.probe.preparationCount == 2)
        #expect(fixture.probe.fadeStepCount == 0)
        #expect(fixture.finishCount == 0)
        #expect(fixture.errors.isEmpty)
    }

    @Test(arguments: ConfigurationRecoveryInterruption.allCases)
    func newUserIntentPreventsARecoveryFromStartingObsoleteAudio(
        interruption: ConfigurationRecoveryInterruption
    ) async throws {
        let fixture = try await ConfigurationRecoveryFixture()
        defer { fixture.remove() }
        _ = try await fixture.beginRecovery()

        switch interruption {
        case .pause: fixture.service.pause()
        case .stop: fixture.service.stop(reset: true)
        case .load: fixture.service.load(url: fixture.replacement.url)
        case .suspend: fixture.service.suspend()
        }
        fixture.probe.releasePreparation()
        _ = await fixture.service.isEngineRunning
        if interruption == .load {
            try await fixture.waitUntil { fixture.loadCount == 2 }
            #expect(fixture.service.duration == 3)
        }

        // A stale player.play() would make the queued user operation fade out the
        // briefly restarted audio. Checking final stopped state alone misses that bug.
        #expect(fixture.probe.fadeStepCount == 0)
        #expect(fixture.probe.preparationCount == 2)
        let stoppedTime = fixture.service.currentTime
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(fixture.service.currentTime - stoppedTime) < 0.001)
        if interruption != .pause { #expect(stoppedTime == 0) }
        #expect(fixture.finishCount == 0)
        #expect(fixture.errors.isEmpty)
    }

    @Test func aNewPlayRequestReplacesTheSegmentPreparedByRecovery() async throws {
        let fixture = try await ConfigurationRecoveryFixture(seconds: 1)
        defer { fixture.remove() }
        _ = try await fixture.beginRecovery()
        let savedTime = fixture.service.currentTime
        fixture.service.play()
        fixture.probe.releasePreparation()

        #expect(await fixture.service.isEngineRunning)
        // The old prepared segment must be invalidated before the new request
        // schedules its own segment, rather than continuing the obsolete play.
        #expect(fixture.probe.preparationCount == 3)
        #expect(fixture.probe.fadeStepCount == 0)
        try await fixture.waitUntil { fixture.service.currentTime > savedTime + 0.05 }
        try await fixture.waitUntil { fixture.finishCount == 1 }
        _ = await fixture.service.isEngineRunning
        #expect(fixture.finishCount == 1)
        #expect(abs(fixture.service.currentTime - 1) < 0.001)
        #expect(fixture.errors.isEmpty)
    }

    @Test func anOldEngineNotificationQueuedAfterResetCannotRestartTheReplacement() async throws {
        let fixture = try await ConfigurationRecoveryFixture()
        defer { fixture.remove() }
        let oldEngine = try await fixture.beginRecovery()
        fixture.service.resetEngine()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: oldEngine)
        fixture.probe.releasePreparation()

        #expect(await fixture.service.isEngineRunning)
        #expect(fixture.probe.engineCount == 2)
        #expect(fixture.probe.preparationCount == 3)
        let resumedTime = fixture.service.currentTime
        try await fixture.waitUntil { fixture.service.currentTime > resumedTime + 0.05 }
        #expect(fixture.probe.preparationCount == 3)
        #expect(fixture.finishCount == 0)
        #expect(fixture.errors.isEmpty)
    }
}

nonisolated enum ConfigurationRecoveryInterruption: CaseIterable {
    case pause
    case stop
    case load
    case suspend
}

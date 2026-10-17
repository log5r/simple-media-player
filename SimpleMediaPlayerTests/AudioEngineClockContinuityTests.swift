import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.serialized)
struct AudioEngineClockContinuityTests {
    @Test(arguments: AudioClockTransportChange.allCases)
    func pauseStopAndRebuildDoNotReplaceTheAudiblePositionWithTheInputPosition(
        change: AudioClockTransportChange
    ) async throws {
        let fixture = try await ConfigurationRecoveryFixture()
        defer { fixture.remove() }
        fixture.service.seek(to: 1, autoPlay: true)
        _ = await fixture.service.isEngineRunning
        try await fixture.waitUntil { fixture.service.currentTime > 1.02 }
        let before = fixture.service.currentTime
        let started = ProcessInfo.processInfo.systemUptime
        switch change {
        case .pause: fixture.service.pause()
        case .stopKeepingPosition: fixture.service.stop(reset: false)
        case .rebuild: fixture.service.resetEngine()
        }
        _ = await fixture.service.isEngineRunning
        fixture.service.pause()
        _ = await fixture.service.isEngineRunning
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let paused = fixture.service.currentTime

        // Allow genuine playback while the operation was queued, plus tap rounding.
        // Reading the input node clock instead adds the 120 ms pitch delay here.
        #expect(paused >= before - 0.03)
        #expect(paused <= before + elapsed + 0.03)
        let resumedAt = ProcessInfo.processInfo.systemUptime
        fixture.service.play()
        _ = await fixture.service.isEngineRunning
        fixture.service.pause()
        _ = await fixture.service.isEngineRunning
        let resumedElapsed = ProcessInfo.processInfo.systemUptime - resumedAt
        #expect(fixture.service.currentTime >= paused - 0.03)
        #expect(fixture.service.currentTime <= paused + resumedElapsed + 0.03)
        #expect(fixture.finishCount == 0)
        #expect(fixture.errors.isEmpty)
    }
}

nonisolated enum AudioClockTransportChange: CaseIterable {
    case pause
    case stopKeepingPosition
    case rebuild
}

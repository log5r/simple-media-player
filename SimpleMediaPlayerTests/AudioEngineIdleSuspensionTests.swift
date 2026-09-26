import Foundation
import Testing
@testable import SimpleMediaPlayer

struct AudioEngineIdleSuspensionTests {
    @Test func dryOrDisabledEqualizerKeepsOnlyAShortDrainPeriod() {
        var settings = EqualizerSettings.flat
        settings.reverbWetDryMix = 100
        settings.reverbPreset = .largeHall
        #expect(AudioEngineIdleSuspension.tailDuration(for: settings) == 0.25)

        settings.isEnabled = true
        settings.reverbWetDryMix = 0
        #expect(AudioEngineIdleSuspension.tailDuration(for: settings) == 0.25)
    }

    @Test(arguments: EqualizerReverbPreset.allCases)
    func reverbHasABoundedDrainPeriod(preset: EqualizerReverbPreset) {
        var settings = EqualizerSettings.flat
        settings.isEnabled = true
        settings.reverbWetDryMix = 100
        settings.reverbPreset = preset
        let duration = AudioEngineIdleSuspension.tailDuration(for: settings)

        #expect(duration >= 1)
        #expect(duration <= 3)
        let expected: TimeInterval = switch preset {
        case .smallRoom: 1
        case .mediumRoom: 1.5
        case .largeHall: 3
        }
        #expect(duration == expected)
    }

    @Test func engineSuspensionWaitsForTheTailAndOccursOnce() {
        let fixture = IdleSuspensionFixture()
        fixture.request()
        #expect(fixture.suspensionCount == 0)
        #expect(fixture.requestedDelays == [0.25])

        fixture.fireRequest(at: 0)
        fixture.fireRequest(at: 0)
        #expect(fixture.suspensionCount == 1)
    }

    @Test func resumingCancelsAnAlreadyScheduledSuspension() {
        let fixture = IdleSuspensionFixture()
        fixture.request()
        fixture.cancel()
        fixture.fireRequest(at: 0)
        #expect(fixture.suspensionCount == 0)
    }

    @Test func replacingThePendingRequestCannotSuspendTheNewPlayback() {
        let fixture = IdleSuspensionFixture()
        fixture.request()
        fixture.cancel()
        var settings = EqualizerSettings.flat
        settings.isEnabled = true
        settings.reverbWetDryMix = 50
        settings.reverbPreset = .largeHall
        fixture.request(settings: settings)

        fixture.fireRequest(at: 0)
        #expect(fixture.suspensionCount == 0)
        #expect(fixture.requestedDelays == [0.25, 3])

        fixture.fireRequest(at: 1)
        #expect(fixture.suspensionCount == 1)
    }

    @Test func repeatedStopsReplaceThePreviousDrainDeadline() {
        let fixture = IdleSuspensionFixture()
        fixture.request()
        fixture.request()
        fixture.fireRequest(at: 0)
        #expect(fixture.suspensionCount == 0)

        fixture.fireRequest(at: 1)
        #expect(fixture.suspensionCount == 1)
    }

    @Test func releasingTheOwnerDiscardsThePendingSuspension() {
        let fixture = IdleSuspensionFixture()
        fixture.request()
        fixture.releaseSuspension()
        fixture.fireRequest(at: 0)
        #expect(fixture.suspensionCount == 0)
    }
}

private final class IdleSuspensionFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AudioEngineIdleSuspensionTests.control")
    private var suspension: AudioEngineIdleSuspension?
    private var requests: [(TimeInterval, DispatchWorkItem)] = []
    private var count = 0

    init() {
        suspension = AudioEngineIdleSuspension(controlQueue: queue) { [weak self] delay, work in
            self?.requests.append((delay, work))
        }
    }

    var suspensionCount: Int { queue.sync { count } }
    var requestedDelays: [TimeInterval] { queue.sync { requests.map(\.0) } }

    func request(settings: EqualizerSettings = .flat) {
        queue.sync {
            suspension?.request(settings: settings) { [weak self] in
                self?.count += 1
            }
        }
    }

    func cancel() {
        queue.sync { suspension?.cancel() }
    }

    func fireRequest(at index: Int) {
        queue.sync { requests[index].1.perform() }
    }

    func releaseSuspension() {
        queue.sync { suspension = nil }
    }
}

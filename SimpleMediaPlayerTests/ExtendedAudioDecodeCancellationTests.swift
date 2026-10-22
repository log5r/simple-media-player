import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct ExtendedAudioDecodeCancellationTests {
    @Test(arguments: DecodeCancellationPoint.allCases, [false, true])
    func wmaCancellationAfterPCMOrDuringDrainDiscardsOutput(
        point: DecodeCancellationPoint, validationOnly: Bool
    ) async throws {
        try await cancelActualDecode(extension: "wma", at: point.stage, validationOnly: validationOnly)
    }

    @Test(arguments: ["wv", "ape", "mpc"], [false, true])
    func sfbCancellationAfterPCMDiscardsOutput(fileExtension: String, validationOnly: Bool) async throws {
        try await cancelActualDecode(extension: fileExtension, at: .frames, validationOnly: validationOnly)
    }

    @Test(arguments: ["wv", "ape", "mpc"])
    func sfbCancellationAfterFinalDecodeCannotPublishCache(fileExtension: String) async throws {
        try await cancelActualDecode(extension: fileExtension, at: .complete, validationOnly: false)
    }

    @Test func shortWMACanProduceItsFirstPCMWhileDraining() throws {
        let source = ExtendedAudioSignalFixture.bundled("short-wma", extension: "wma")
        let fixture = try ExtendedAudioSignalFixture()
        defer { fixture.remove() }
        let destination = fixture.directory.appendingPathComponent("short.caf")
        let probe = DecodeCancellationProbe(cancelAt: nil)
        try SMPFFmpegAudio.decode(
            source, toCAF: destination, maxBytes: 1_048_576, shouldCancel: { false },
            observer: { stage, frames in probe.observe(stage: stage, frames: frames, temporary: destination) }
        )
        #expect(probe.events.contains { $0.stage == .decoderDrain && $0.frames > 0 })
        #expect(probe.events.contains { $0.stage == .frames && $0.frames > 0 } == false)
        #expect(try AVAudioFile(forReading: destination).length == 2_048)
        #expect(probe.events.last?.stage == .complete)
    }

    private func cancelActualDecode(
        extension fileExtension: String, at stage: SMPAudioDecodeStage, validationOnly: Bool
    ) async throws {
        let fixture = try ExtendedAudioSignalFixture()
        defer { fixture.remove() }
        let source = try fixture.source(extension: fileExtension)
        let original = try Data(contentsOf: source)
        let cache = try #require(ExtendedAudioSource.cacheURL(for: source))
        defer { ExtendedAudioSource.removeCache(for: source) }
        let probe = DecodeCancellationProbe(cancelAt: stage)
        let task = Task.detached(executorPreference: BlockingWorkExecutor.shared) {
            try ExtendedAudioSource.$decodeObserver.withValue({ stage, frames, temporary in
                probe.observe(stage: stage, frames: frames, temporary: temporary)
            }, operation: {
                if validationOnly {
                    try ExtendedAudioSource.validate(for: source)
                } else {
                    let readable = try ExtendedAudioSource.readableFile(for: source)
                    readable.release()
                }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let interrupted = try #require(probe.events.first { $0.stage == stage && $0.frames > 0 })
        #expect(interrupted.frames > 0, "The real decoder must produce PCM before cancellation.")
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
        if validationOnly {
            #expect(probe.events.allSatisfy { $0.temporary == nil })
        } else {
            let partial = try #require(interrupted.temporary)
            #expect(FileManager.default.fileExists(atPath: partial.path) == false)
        }
        #expect(try Data(contentsOf: source) == original)
        // A cancelled decode must leave neither a poisoned cache nor a producer entry.
        let readable = try ExtendedAudioSource.readableFile(for: source)
        defer { readable.release() }
        #expect(try AVAudioFile(forReading: readable.url).length > 0)
    }
}

nonisolated enum DecodeCancellationPoint: CaseIterable, Sendable {
    case frames
    case decoderDrain
    case resamplerDrain
    case complete

    var stage: SMPAudioDecodeStage {
        switch self {
        case .frames: .frames
        case .decoderDrain: .decoderDrain
        case .resamplerDrain: .resamplerDrain
        case .complete: .complete
        }
    }
}

nonisolated private final class DecodeCancellationProbe: @unchecked Sendable {
    struct Event {
        let stage: SMPAudioDecodeStage
        let frames: Int64
        let temporary: URL?
    }
    private let lock = NSLock()
    private let cancelAt: SMPAudioDecodeStage?
    private var recorded: [Event] = []
    var events: [Event] { lock.withLock { recorded } }

    init(cancelAt: SMPAudioDecodeStage?) { self.cancelAt = cancelAt }

    func observe(stage: SMPAudioDecodeStage, frames: Int64, temporary: URL?) {
        lock.withLock { recorded.append(Event(stage: stage, frames: frames, temporary: temporary)) }
        if stage == cancelAt, frames > 0 { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

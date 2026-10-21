import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct VideoSpectrumSourceTimelineTests {
    enum Discontinuity: CaseIterable {
        case timeGap
        case startsStream
        case sampleRate
    }

    @Test(arguments: VisualizerResponseMode.allCases)
    func continuousSourceRangesRetainPartialPCMDespiteDifferentDurations(mode: VisualizerResponseMode) throws {
        let accumulator = VideoSpectrumAccumulator()
        var first = batch(value: 1, count: 4_096, time: 0)
        first.sourceEndTime = 0.081375
        var second = batch(value: 2, count: 4_096, time: 0.081375)
        second.sourceEndTime = 0.174375

        let firstResult = accumulator.append(first, mode: mode)
        let secondResult = accumulator.append(second, mode: mode)

        #expect(firstResult.didReset)
        #expect(!secondResult.didReset)
        let chunkFrames = Int(48_000 / mode.framesPerSecond)
        #expect(firstResult.chunks.count + secondResult.chunks.count == 8_192 / chunkFrames)
        let continuedChunk = try #require(secondResult.chunks.first)
        let retainedCount = 4_096 % chunkFrames
        #expect(Array(continuedChunk.left.prefix(retainedCount)) == Array(repeating: 1, count: retainedCount))
        #expect(Array(continuedChunk.right.prefix(retainedCount)) == Array(repeating: -1, count: retainedCount))
        #expect(continuedChunk.left.dropFirst(retainedCount).allSatisfy { $0 == 2 })
        #expect(continuedChunk.right.dropFirst(retainedCount).allSatisfy { $0 == -2 })
    }

    @Test(arguments: Discontinuity.allCases)
    func actualDiscontinuitiesDiscardPartialPCM(reason: Discontinuity) throws {
        let accumulator = VideoSpectrumAccumulator()
        var first = batch(value: 1, count: 512, time: 0)
        first.sourceEndTime = 0.081375
        let firstResult = accumulator.append(first, mode: .normal)
        #expect(firstResult.chunks.isEmpty)
        var second = batch(
            value: 0, count: 1_600, time: reason == .timeGap ? 1 : 0.081375,
            startsStream: reason == .startsStream, sampleRate: reason == .sampleRate ? 44_100 : 48_000
        )
        second.sourceEndTime = second.time + 0.093

        let result = accumulator.append(second, mode: .normal)

        #expect(result.didReset)
        let chunk = try #require(result.chunks.first)
        #expect(chunk.left.allSatisfy { $0 == 0 })
        #expect(chunk.right.allSatisfy { $0 == 0 })
    }

    private func batch(
        value: Float, count: Int, time: TimeInterval, startsStream: Bool = false, sampleRate: Double = 48_000
    ) -> VideoAudioSampleRing.Batch {
        VideoAudioSampleRing.Batch(
            left: Array(repeating: value, count: count), right: Array(repeating: -value, count: count),
            sampleRate: sampleRate, time: time, analysisGeneration: 1, sourceEpoch: 3, startsStream: startsStream
        )
    }
}

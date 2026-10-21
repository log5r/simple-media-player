import Foundation

// Confined to SpectrumAnalyzer's serial queue. Sample windows span tap callbacks,
// so the visualizer's rate is independent of the tap's maximum frame count.
nonisolated final class VideoSpectrumAccumulator {
    struct Chunk: Sendable {
        let left: [Float]
        let right: [Float]
        let time: TimeInterval
    }

    struct Result {
        let chunks: [Chunk]
        let didReset: Bool
    }

    private var left: [Float] = []
    private var right: [Float] = []
    private var nextTime: TimeInterval?
    private var expectedSourceTime: TimeInterval?
    private var sampleRate = 0.0
    private var sourceEpoch: UInt64 = 0
    private var generation = 0
    private var mode: VisualizerResponseMode?
    private(set) var revision = 0

    func append(_ batch: VideoAudioSampleRing.Batch, mode: VisualizerResponseMode) -> Result {
        // The tap supplies an asset time range, whose duration need not equal
        // its PCM frame count / sample rate. Keep this separate from the chunk clock.
        let didReset = batch.startsStream || generation != batch.analysisGeneration
            || sourceEpoch != batch.sourceEpoch || sampleRate != batch.sampleRate || self.mode != mode
            || expectedSourceTime.map({ abs($0 - batch.time) > 2 / batch.sampleRate }) == true
        if didReset { reset() }
        generation = batch.analysisGeneration
        sourceEpoch = batch.sourceEpoch
        sampleRate = batch.sampleRate
        self.mode = mode
        expectedSourceTime = batch.sourceEndTime.flatMap {
            $0.isFinite && $0 >= batch.time ? $0 : nil
        } ?? batch.time + Double(batch.left.count) / batch.sampleRate
        if nextTime == nil { nextTime = batch.time }
        left.append(contentsOf: batch.left)
        right.append(contentsOf: batch.right)
        let chunkFrames = max(1, Int(batch.sampleRate / mode.framesPerSecond))
        var chunks: [Chunk] = []
        while left.count >= chunkFrames {
            let time = nextTime ?? batch.time
            chunks.append(Chunk(
                left: Array(left.prefix(chunkFrames)), right: Array(right.prefix(chunkFrames)), time: time
            ))
            left.removeFirst(chunkFrames)
            right.removeFirst(chunkFrames)
            nextTime = time + Double(chunkFrames) / batch.sampleRate
        }
        return Result(chunks: chunks, didReset: didReset)
    }

    func reset() {
        left.removeAll(keepingCapacity: true)
        right.removeAll(keepingCapacity: true)
        nextTime = nil
        expectedSourceTime = nil
        revision &+= 1
    }
}

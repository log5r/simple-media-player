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
    private var sampleRate = 0.0
    private var sourceEpoch: UInt64 = 0
    private var generation = 0
    private var mode: VisualizerResponseMode?
    private(set) var revision = 0

    func append(_ batch: VideoAudioSampleRing.Batch, mode: VisualizerResponseMode) -> Result {
        let expectedTime = nextTime.map { $0 + Double(left.count) / batch.sampleRate }
        let didReset = batch.startsStream || generation != batch.analysisGeneration
            || sourceEpoch != batch.sourceEpoch || sampleRate != batch.sampleRate || self.mode != mode
            || expectedTime.map({ abs($0 - batch.time) > 2 / batch.sampleRate }) == true
        if didReset { reset() }
        generation = batch.analysisGeneration
        sourceEpoch = batch.sourceEpoch
        sampleRate = batch.sampleRate
        self.mode = mode
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
        revision &+= 1
    }
}

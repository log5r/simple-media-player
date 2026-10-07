import AVFoundation
import Synchronization

// MainActor controls the source epoch; the tap only reads it. Every transport change
// invalidates queued samples, including a pause followed immediately by a resume.
nonisolated final class VideoAudioTapState: Sendable {
    let epoch = Atomic<UInt64>(0)

    @discardableResult
    func setActive(_ active: Bool) -> UInt64 {
        let previous = epoch.load(ordering: .relaxed)
        let next = ((previous & ~1) &+ 2) | (active ? 1 : 0)
        epoch.store(next, ordering: .releasing)
        return next
    }
}

// One producer (tap) and one consumer (timer queue). A full ring drops visualization
// samples rather than waiting. Only the consumer allocates arrays or dispatches work.
nonisolated final class VideoAudioSampleRing: @unchecked Sendable {
    struct Batch: Sendable {
        let left: [Float]
        let right: [Float]
        let sampleRate: Double
        let time: TimeInterval
        let analysisGeneration: Int
        let sourceEpoch: UInt64
        let startsStream: Bool
    }

    struct Stamp {
        let time: TimeInterval
        let analysisGeneration: Int
        let sourceEpoch: UInt64
        let startsStream: Bool
    }

    private struct Slot {
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        var count = 0
        var time: TimeInterval = 0
        var analysisGeneration = 0
        var sourceEpoch: UInt64 = 0
        var startsStream = false
    }

    private let slots: UnsafeMutablePointer<Slot>
    private let slotCount: Int
    private let maxFrames: Int
    private let channelCount: Int
    private let interleaved: Bool
    private let sampleRate: Double
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let accepting = Atomic<Bool>(true)
    private let state: VideoAudioTapState
    private var timer: DispatchSourceTimer?
    // Producer-only flag: a dropped buffer breaks the consumer's sample history.
    private var needsDiscontinuity = false

    init(maxFrames: Int, format: AVAudioFormat, state: VideoAudioTapState, slotCount: Int = 8) {
        precondition(maxFrames > 0 && slotCount > 1)
        self.maxFrames = maxFrames
        self.slotCount = slotCount
        self.channelCount = Int(format.channelCount)
        self.interleaved = format.isInterleaved
        self.sampleRate = format.sampleRate
        self.state = state
        slots = .allocate(capacity: slotCount)
        for index in 0..<slotCount {
            let left = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            left.initialize(repeating: 0, count: maxFrames)
            right.initialize(repeating: 0, count: maxFrames)
            slots.advanced(by: index).initialize(to: Slot(left: left, right: right))
        }
    }

    deinit {
        timer?.cancel()
        for index in 0..<slotCount {
            slots[index].left.deinitialize(count: maxFrames)
            slots[index].left.deallocate()
            slots[index].right.deinitialize(count: maxFrames)
            slots[index].right.deallocate()
        }
        slots.deinitialize(count: slotCount)
        slots.deallocate()
    }

    func start(analyzer: SpectrumAnalyzer) {
        let timer = analyzer.makeVideoSampleTimer(for: self)
        self.timer = timer
        timer.resume()
    }

    func stop() {
        accepting.store(false, ordering: .releasing)
        timer?.cancel()
    }

    func isCurrent(_ batch: Batch) -> Bool {
        accepting.load(ordering: .acquiring)
            && batch.sourceEpoch & 1 == 1
            && state.epoch.load(ordering: .acquiring) == batch.sourceEpoch
    }

    @discardableResult
    func enqueue(
        _ buffers: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        stamp: Stamp
    ) -> Bool {
        guard accepting.load(ordering: .acquiring), stamp.sourceEpoch & 1 == 1,
              stamp.analysisGeneration != 0, stamp.time.isFinite,
              frameCount > 0, frameCount <= maxFrames else { return false }
        let index = writeIndex.load(ordering: .relaxed)
        let next = (index + 1) % slotCount
        guard next != readIndex.load(ordering: .acquiring) else {
            needsDiscontinuity = true
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        let rightIndex = channelCount > 1 ? 1 : 0
        let stride = interleaved ? channelCount : 1
        guard list.count >= (interleaved ? 1 : channelCount),
              let leftData = list[0].mData,
              let rightData = list[interleaved ? 0 : rightIndex].mData,
              Int(list[0].mDataByteSize) >= frameCount * stride * MemoryLayout<Float>.size,
              Int(list[interleaved ? 0 : rightIndex].mDataByteSize)
                >= frameCount * stride * MemoryLayout<Float>.size else { return false }
        let left = leftData.assumingMemoryBound(to: Float.self)
        let right = rightData.assumingMemoryBound(to: Float.self)
        let slot = slots.advanced(by: index)
        if interleaved {
            for frame in 0..<frameCount {
                slot.pointee.left[frame] = left[frame * stride]
                slot.pointee.right[frame] = right[frame * stride + rightIndex]
            }
        } else {
            slot.pointee.left.update(from: left, count: frameCount)
            slot.pointee.right.update(from: right, count: frameCount)
        }
        slot.pointee.count = frameCount
        slot.pointee.time = stamp.time
        slot.pointee.analysisGeneration = stamp.analysisGeneration
        slot.pointee.sourceEpoch = stamp.sourceEpoch
        slot.pointee.startsStream = stamp.startsStream || needsDiscontinuity
        needsDiscontinuity = false
        // Publish PCM and metadata together, after the entire slot has been copied.
        writeIndex.store(next, ordering: .releasing)
        return true
    }

    func drain(_ consume: (Batch) -> Void) {
        // Bound each timer invocation even when the producer continues writing.
        let end = writeIndex.load(ordering: .acquiring)
        var index = readIndex.load(ordering: .relaxed)
        while index != end {
            let slot = slots[index]
            let batch = Batch(
                left: Array(UnsafeBufferPointer(start: slot.left, count: slot.count)),
                right: Array(UnsafeBufferPointer(start: slot.right, count: slot.count)),
                sampleRate: sampleRate, time: slot.time,
                analysisGeneration: slot.analysisGeneration, sourceEpoch: slot.sourceEpoch,
                startsStream: slot.startsStream
            )
            index = (index + 1) % slotCount
            readIndex.store(index, ordering: .releasing)
            if isCurrent(batch) { consume(batch) }
        }
    }
}

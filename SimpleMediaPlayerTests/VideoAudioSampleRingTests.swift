import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import SimpleMediaPlayer

struct VideoAudioSampleRingTests {
    @Test(arguments: [1, 2], [false, true])
    func copiesFloatPCMWithoutBorrowingSourceStorage(channels: Int, interleaved: Bool) throws {
        let buffer = try makeBuffer(channels: channels, interleaved: interleaved)
        let state = VideoAudioTapState()
        let epoch = state.setActive(true)
        let ring = VideoAudioSampleRing(maxFrames: 8, format: buffer.format, state: state)
        fill(buffer, left: 0.25, right: -0.5)
        #expect(enqueue(ring, buffer, epoch: epoch))
        fill(buffer, left: 0, right: 0)
        var batches: [VideoAudioSampleRing.Batch] = []
        ring.drain { batches.append($0) }
        let batch = try #require(batches.first)
        #expect(batch.left == Array(repeating: 0.25, count: 8))
        #expect(batch.right == Array(repeating: channels == 1 ? 0.25 : -0.5, count: 8))
    }

    @Test func fullRingDropsInputAndMarksNextAcceptedBufferAsDiscontinuous() throws {
        let buffer = try makeBuffer()
        let state = VideoAudioTapState()
        let epoch = state.setActive(true)
        let ring = VideoAudioSampleRing(maxFrames: 8, format: buffer.format, state: state, slotCount: 3)
        fill(buffer, left: 1, right: 2)
        #expect(enqueue(ring, buffer, epoch: epoch))
        fill(buffer, left: 3, right: 4)
        #expect(enqueue(ring, buffer, epoch: epoch))
        fill(buffer, left: 5, right: 6)
        #expect(enqueue(ring, buffer, epoch: epoch) == false)
        var values: [Float] = []
        ring.drain { values.append($0.left[0]) }
        #expect(values == [1, 3])
        #expect(enqueue(ring, buffer, epoch: epoch))
        ring.drain {
            #expect($0.startsStream)
            #expect($0.left[0] == 5)
        }
    }

    @Test func pauseResumeSeekAndUnprepareRejectQueuedOrLateSamples() throws {
        let buffer = try makeBuffer()
        let state = VideoAudioTapState()
        let epoch = state.setActive(true)
        let ring = VideoAudioSampleRing(maxFrames: 8, format: buffer.format, state: state)
        #expect(enqueue(ring, buffer, epoch: epoch))
        state.setActive(false)
        let resumed = state.setActive(true)
        // Simulate a callback which began before the transport change but publishes after it.
        #expect(enqueue(ring, buffer, epoch: epoch))
        var count = 0
        ring.drain { _ in count += 1 }
        #expect(count == 0)
        #expect(enqueue(ring, buffer, epoch: resumed))
        var batch: VideoAudioSampleRing.Batch?
        ring.drain { batch = $0 }
        let accepted = try #require(batch)
        #expect(ring.isCurrent(accepted))
        state.setActive(true) // A seek completes into a fresh epoch.
        #expect(ring.isCurrent(accepted) == false)
        ring.stop()
        #expect(enqueue(ring, buffer, epoch: state.epoch.load(ordering: .acquiring)) == false)
    }

    @Test func oversizedAndInactiveBuffersAreRejected() throws {
        let buffer = try makeBuffer()
        let state = VideoAudioTapState()
        let ring = VideoAudioSampleRing(maxFrames: 4, format: buffer.format, state: state)
        #expect(enqueue(ring, buffer, epoch: 0) == false)
        #expect(enqueue(ring, buffer, epoch: state.setActive(true)) == false)
        var count = 0
        ring.drain { _ in count += 1 }
        #expect(count == 0)
    }

    @Test func concurrentProducerAndConsumerPreserveWholeSlotsAcrossWraparound() throws {
        let buffer = try makeBuffer()
        let state = VideoAudioTapState()
        let epoch = state.setActive(true)
        let ring = VideoAudioSampleRing(maxFrames: 8, format: buffer.format, state: state, slotCount: 3)
        let done = Atomic<Bool>(false)
        let producer = DispatchGroup()
        producer.enter()
        DispatchQueue.global().async {
            for index in 1...10_000 {
                fill(buffer, left: Float(index), right: -Float(index))
                _ = enqueue(ring, buffer, epoch: epoch)
            }
            done.store(true, ordering: .releasing)
            producer.leave()
        }
        var lastValue: Float = 0
        var count = 0
        func consume(_ batch: VideoAudioSampleRing.Batch) {
            let value = batch.left[0]
            #expect(value > lastValue)
            #expect(batch.left.allSatisfy { $0 == value })
            #expect(batch.right.allSatisfy { $0 == -value })
            lastValue = value
            count += 1
        }
        while done.load(ordering: .acquiring) == false { ring.drain(consume) }
        producer.wait()
        ring.drain(consume)
        #expect(count > 0)
    }
}

private func makeBuffer(channels: Int = 2, interleaved: Bool = false) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
        channels: AVAudioChannelCount(channels), interleaved: interleaved
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    buffer.frameLength = 8
    return buffer
}

private func fill(_ buffer: AVAudioPCMBuffer, left: Float, right: Float) {
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let channels = Int(buffer.format.channelCount)
    for frame in 0..<Int(buffer.frameLength) {
        for channel in 0..<channels {
            let samples = list[buffer.format.isInterleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
            samples[buffer.format.isInterleaved ? frame * channels + channel : frame] = channel == 0 ? left : right
        }
    }
}

private func enqueue(_ ring: VideoAudioSampleRing, _ buffer: AVAudioPCMBuffer, epoch: UInt64) -> Bool {
    ring.enqueue(
        buffer.mutableAudioBufferList, frameCount: Int(buffer.frameLength),
        stamp: .init(time: 0, analysisGeneration: 1, sourceEpoch: epoch, startsStream: false)
    )
}

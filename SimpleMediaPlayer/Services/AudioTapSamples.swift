import AVFoundation
import Synchronization

// One slot per installed audio tap. A successful producer hands exclusive access
// to the FFT queue, which releases it after copying any chunks needed for later frames.
nonisolated final class AudioTapSamples: @unchecked Sendable {
    private let occupied = Atomic<Bool>(false)
    private var left: [Float]
    private var right: [Float]
    private(set) var frameCount = 0
    private var lastGeneration = 0
    private var lastAcceptedTime: TimeInterval = 0

    init(capacity: Int) {
        left = Array(repeating: 0, count: capacity)
        right = Array(repeating: 0, count: capacity)
    }

    func copyIfAvailable(_ buffer: AVReadOnlyAudioPCMBuffer, generation: Int) -> Bool {
        guard occupied.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else {
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        let count = buffer.frameLength
        guard generation != lastGeneration || now - lastAcceptedTime >= 1.0 / 60.0,
              count > 0, count <= left.count, buffer.stride == 1,
              case let .float(leftSamples) = buffer.channelData(0),
              case let .float(rightSamples) = buffer.channelData(buffer.format.channelCount > 1 ? 1 : 0),
              leftSamples.count >= count, rightSamples.count >= count else {
            release()
            return false
        }

        Self.copy(leftSamples, count: count, into: &left)
        Self.copy(rightSamples, count: count, into: &right)
        frameCount = count
        lastAcceptedTime = now
        lastGeneration = generation
        return true
    }

    // The worker gets independent storage. Even a delayed full-length chunk
    // must never share an Array backing store with the next tap callback.
    func channels(in range: Range<Int>) -> ([Float], [Float]) {
        (left.withUnsafeBufferPointer { Array($0[range]) },
         right.withUnsafeBufferPointer { Array($0[range]) })
    }

    func release() {
        occupied.store(false, ordering: .releasing)
    }

    private static func copy(_ source: Span<Float>, count: Int, into destination: inout [Float]) {
        source.withUnsafeBufferPointer { samples in
            destination.withUnsafeMutableBufferPointer { output in
                output.baseAddress!.update(from: samples.baseAddress!, count: count)
            }
        }
    }
}

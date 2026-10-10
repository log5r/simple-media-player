import Accelerate
import AVFoundation
import Foundation

nonisolated enum AudioLoudnessNormalizer {
    static let minimumGainDecibels: Float = -24
    static let maximumGainDecibels: Float = 12

    private static let targetLevelDecibels = -18.0
    private static let absoluteGateDecibels = -70.0
    private static let relativeGateDecibels = -10.0
    private static let maximumPeakAmplitude = 0.95

    /// Returns the stored gain without reading the audio, or nil when the file has not been measured.
    static func cachedGain(for url: URL, cacheDirectory: URL? = AudioLoudnessCache.defaultDirectory) -> Float? {
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess { url.stopAccessingSecurityScopedResource() }
        }
        return AudioLoudnessCache.entryURL(for: url, in: cacheDirectory).flatMap(AudioLoudnessCache.read(at:))
    }

    static func cachedOrMeasuredGain(
        for url: URL, cacheDirectory: URL? = AudioLoudnessCache.defaultDirectory
    ) throws -> Float {
        try cachedOrMeasuredGain(for: url, cacheDirectory: cacheDirectory, measure: measuredGain)
    }

    static func cachedOrMeasuredGain(
        for url: URL,
        cacheDirectory: URL?,
        measure: (URL) throws -> Float
    ) throws -> Float {
        try Task.checkCancellation()
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        let entry = AudioLoudnessCache.entryURL(for: url, in: cacheDirectory)
        if let entry, let cachedGain = AudioLoudnessCache.read(at: entry) {
            try Task.checkCancellation()
            return cachedGain
        }

        let gain: Float
        do {
            gain = try measure(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            gain = 0
        }
        try Task.checkCancellation()
        if let entry {
            AudioLoudnessCache.store(gain, at: entry, for: url, in: cacheDirectory)
        }
        return gain
    }

    static func gainDecibels(forBlockMeanSquares blockMeanSquares: [Double], peakAmplitude: Float) -> Float {
        let absoluteGatePower = pow(10, absoluteGateDecibels / 10)
        let audibleBlocks = blockMeanSquares.filter { $0.isFinite && $0 > absoluteGatePower }
        guard audibleBlocks.isEmpty == false else { return 0 }

        let ungatedMeanSquare = audibleBlocks.reduce(0, +) / Double(audibleBlocks.count)
        let relativeGatePower = ungatedMeanSquare * pow(10, relativeGateDecibels / 10)
        let gatePower = max(absoluteGatePower, relativeGatePower)
        let gatedBlocks = audibleBlocks.filter { $0 >= gatePower }
        guard gatedBlocks.isEmpty == false else { return 0 }

        let integratedMeanSquare = gatedBlocks.reduce(0, +) / Double(gatedBlocks.count)
        guard integratedMeanSquare.isFinite, integratedMeanSquare > 0 else { return 0 }

        let measuredLevel = 10 * log10(integratedMeanSquare)
        var gain = targetLevelDecibels - measuredLevel

        if peakAmplitude.isFinite, peakAmplitude > 0 {
            let peakHeadroom = 20 * log10(maximumPeakAmplitude / Double(peakAmplitude))
            gain = min(gain, peakHeadroom)
        }

        return Float(max(Double(minimumGainDecibels), min(Double(maximumGainDecibels), gain)))
    }

    private static func measuredGain(for url: URL) throws -> Float {
        try Task.checkCancellation()
        let source = try ExtendedAudioSource.readableFile(for: url)
        defer { source.release() }
        let file = try AVAudioFile(forReading: source.url)
        return try measuredGain(in: file)
    }

    private static func measuredGain(in file: AVAudioFile) throws -> Float {
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)
        else {
            return 0
        }

        var accumulator = BlockAccumulator(
            channelCount: channelCount,
            blockFrameCapacity: max(1, Int(format.sampleRate * 0.4)),
            expectedFrameCount: Int(file.length)
        )

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            try Task.checkCancellation()
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let channelData = buffer.floatChannelData else { break }
            accumulator.add(channelData, frameCount: frameLength)
        }

        let measurement = accumulator.finish()
        try Task.checkCancellation()
        return gainDecibels(forBlockMeanSquares: measurement.blockMeanSquares, peakAmplitude: measurement.peakAmplitude)
    }

    /// Splits deinterleaved samples into 0.4-second blocks and keeps the peak magnitude and each block's mean square.
    nonisolated struct BlockAccumulator {
        private let channelCount: Int
        private let blockFrameCapacity: Int
        private var blockMeanSquares: [Double] = []
        private var blockSquareSum = 0.0
        private var blockFrameCount = 0
        private var peakAmplitude: Float = 0

        init(channelCount: Int, blockFrameCapacity: Int, expectedFrameCount: Int = 0) {
            self.channelCount = channelCount
            self.blockFrameCapacity = blockFrameCapacity
            blockMeanSquares.reserveCapacity(max(1, expectedFrameCount / blockFrameCapacity))
        }

        /// Adds `frameCount` frames from each of `channelCount` channels. A block may continue into the next call.
        mutating func add(_ channelData: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
            var frameOffset = 0
            while frameOffset < frameCount {
                let framesToConsume = min(blockFrameCapacity - blockFrameCount, frameCount - frameOffset)
                for channelIndex in 0..<channelCount {
                    accumulate(channelData[channelIndex] + frameOffset, count: framesToConsume)
                }

                blockFrameCount += framesToConsume
                frameOffset += framesToConsume

                if blockFrameCount == blockFrameCapacity {
                    blockMeanSquares.append(blockSquareSum / Double(blockFrameCount * channelCount))
                    blockSquareSum = 0
                    blockFrameCount = 0
                }
            }
        }

        /// Closes the trailing partial block.
        mutating func finish() -> (blockMeanSquares: [Double], peakAmplitude: Float) {
            if blockFrameCount > 0 {
                blockMeanSquares.append(blockSquareSum / Double(blockFrameCount * channelCount))
                blockSquareSum = 0
                blockFrameCount = 0
            }
            return (blockMeanSquares, peakAmplitude)
        }

        // vDSP sums the squares in Float. A span holds at most one buffer, so the relative error stays far below
        // 0.01 dB. A non-finite sum means a NaN or infinite sample, or squares beyond the Float range; such a span
        // falls back to the Double loop, which keeps the earlier results: a NaN leaves the peak unchanged and makes
        // the block non-finite, so the gain calculation drops that block.
        private mutating func accumulate(_ samples: UnsafePointer<Float>, count: Int) {
            guard count > 0 else { return }
            var squareSum: Float = 0
            vDSP_svesq(samples, 1, &squareSum, vDSP_Length(count))
            if squareSum.isFinite {
                var spanPeak: Float = 0
                vDSP_maxmgv(samples, 1, &spanPeak, vDSP_Length(count))
                peakAmplitude = max(peakAmplitude, spanPeak)
                blockSquareSum += Double(squareSum)
                return
            }
            for index in 0..<count {
                let sample = samples[index]
                peakAmplitude = max(peakAmplitude, abs(sample))
                blockSquareSum += Double(sample) * Double(sample)
            }
        }
    }
}

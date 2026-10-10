import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct AudioLoudnessMeasurementTests {
    @Test(arguments: MeasurementCase.allCases)
    private func blockAccumulationMatchesTheScalarReference(measurementCase: MeasurementCase) {
        let signal = measurementCase.signal
        let expected = ScalarReference.measure(
            signal.channels, blockFrameCapacity: signal.blockFrameCapacity, bufferFrameCount: signal.bufferFrameCount
        )
        let actual = accumulate(signal)

        #expect(actual.blockMeanSquares.count == expected.blockMeanSquares.count)
        for (actualBlock, expectedBlock) in zip(actual.blockMeanSquares, expected.blockMeanSquares) {
            #expect(abs(actualBlock - expectedBlock) <= expectedBlock * 1e-5)
        }
        #expect(actual.peakAmplitude == expected.peakAmplitude)
        let actualGain = AudioLoudnessNormalizer.gainDecibels(
            forBlockMeanSquares: actual.blockMeanSquares, peakAmplitude: actual.peakAmplitude
        )
        let expectedGain = AudioLoudnessNormalizer.gainDecibels(
            forBlockMeanSquares: expected.blockMeanSquares, peakAmplitude: expected.peakAmplitude
        )
        #expect(abs(actualGain - expectedGain) < 0.001)
        #expect(measurementCase.expectedGainRange.contains(actualGain))
    }

    @Test func nonFiniteSamplesKeepTheScalarResults() {
        var channels = TestSignal.noise(channelCount: 2, frameCount: 120, amplitude: 0.2, seed: 7)
        channels[0][3] = .nan // Block 0: the earlier peak stays and the block becomes NaN.
        channels[1][25] = .infinity // Block 1.
        channels[0][45] = -.infinity // Block 2.
        channels[1][65] = 1e20 // Block 3: its square overflows Float but not Double.
        channels[0][85] = .nan
        channels[1][86] = .infinity // Block 4.
        let signal = TestSignal(channels: channels, blockFrameCapacity: 20, bufferFrameCount: 13)
        let expected = ScalarReference.measure(channels, blockFrameCapacity: 20, bufferFrameCount: 13)
        let actual = accumulate(signal)

        #expect(actual.blockMeanSquares.count == expected.blockMeanSquares.count)
        for (actualBlock, expectedBlock) in zip(actual.blockMeanSquares, expected.blockMeanSquares) {
            if expectedBlock.isNaN {
                #expect(actualBlock.isNaN)
            } else if expectedBlock.isInfinite {
                #expect(actualBlock == expectedBlock)
            } else {
                #expect(abs(actualBlock - expectedBlock) <= expectedBlock * 1e-5)
            }
        }
        #expect(actual.blockMeanSquares[0].isNaN)
        #expect(actual.blockMeanSquares[1] == .infinity)
        #expect(actual.blockMeanSquares[3].isFinite)
        #expect(actual.peakAmplitude == .infinity)
        #expect(actual.peakAmplitude == expected.peakAmplitude)
        #expect(
            AudioLoudnessNormalizer.gainDecibels(
                forBlockMeanSquares: actual.blockMeanSquares, peakAmplitude: actual.peakAmplitude
            ) == AudioLoudnessNormalizer.gainDecibels(
                forBlockMeanSquares: expected.blockMeanSquares, peakAmplitude: expected.peakAmplitude
            )
        )
    }

    @Test func nanSamplesLeaveThePeakOfFiniteSamples() {
        var channels = TestSignal.noise(channelCount: 1, frameCount: 40, amplitude: 0.5, seed: 11)
        channels[0][0] = .nan
        channels[0][39] = .nan
        let signal = TestSignal(channels: channels, blockFrameCapacity: 10, bufferFrameCount: 16)
        let expected = ScalarReference.measure(channels, blockFrameCapacity: 10, bufferFrameCount: 16)
        let actual = accumulate(signal)

        #expect(actual.peakAmplitude == expected.peakAmplitude)
        #expect(actual.peakAmplitude.isFinite)
        #expect(actual.blockMeanSquares.map(\.isNaN) == [true, false, false, true])
    }

    @Test func measuringAFileMatchesTheScalarReference() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioLoudnessMeasurementTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("noise.caf")
        // Blocks of 17,640 frames straddle the 16,384-frame read buffer, and the last block is partial.
        let channels = TestSignal.noise(channelCount: 2, frameCount: 44_100 * 3 + 5_000, amplitude: 0.1, seed: 3)
        try write(channels, sampleRate: 44_100, to: url)

        let gain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(
            for: url, cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true)
        )
        let expected = ScalarReference.measure(channels, blockFrameCapacity: 17_640, bufferFrameCount: 16_384)
        let expectedGain = AudioLoudnessNormalizer.gainDecibels(
            forBlockMeanSquares: expected.blockMeanSquares, peakAmplitude: expected.peakAmplitude
        )

        #expect(expected.blockMeanSquares.count == 8)
        #expect(abs(gain - expectedGain) < 0.001)
        #expect(gain > 1 && gain < AudioLoudnessNormalizer.maximumGainDecibels)
    }

    private func accumulate(_ signal: TestSignal) -> (blockMeanSquares: [Double], peakAmplitude: Float) {
        var accumulator = AudioLoudnessNormalizer.BlockAccumulator(
            channelCount: signal.channels.count, blockFrameCapacity: signal.blockFrameCapacity
        )
        let frameCount = signal.channels.first?.count ?? 0
        let storage = signal.channels.map { samples in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, samples.count))
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }

        var offset = 0
        while offset < frameCount {
            let count = min(signal.bufferFrameCount, frameCount - offset)
            let buffer = storage.map { $0 + offset }
            buffer.withUnsafeBufferPointer { accumulator.add($0.baseAddress!, frameCount: count) }
            offset += count
        }
        return accumulator.finish()
    }

    private func write(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count))
        )
        let frameCount = channels[0].count
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = buffer.frameCapacity
        let channelData = try #require(buffer.floatChannelData)
        for (index, samples) in channels.enumerated() {
            channelData[index].update(from: samples, count: frameCount)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private enum MeasurementCase: CaseIterable, Sendable {
        case stereoNoiseAcrossReadBuffers
        case manyChannelsWithShortBlocks
        case silence
        case clippingPeaks
        case quietNoise

        var signal: TestSignal {
            switch self {
            case .stereoNoiseAcrossReadBuffers:
                TestSignal(
                    channels: TestSignal.noise(channelCount: 2, frameCount: 89_434, amplitude: 0.3, seed: 1),
                    blockFrameCapacity: 17_640, bufferFrameCount: 16_384
                )
            case .manyChannelsWithShortBlocks:
                TestSignal(
                    channels: TestSignal.noise(channelCount: 6, frameCount: 103, amplitude: 0.25, seed: 2),
                    blockFrameCapacity: 7, bufferFrameCount: 5
                )
            case .silence:
                TestSignal(
                    channels: Array(repeating: Array(repeating: 0, count: 50_000), count: 2),
                    blockFrameCapacity: 17_640, bufferFrameCount: 16_384
                )
            case .clippingPeaks:
                TestSignal(
                    channels: (0..<2).map { channel -> [Float] in
                        var samples: [Float] = (0..<40_000).map { ($0 / 50 + channel).isMultiple(of: 2) ? 1 : -1 }
                        if channel == 1 { samples[30_001] = -1.25 }
                        return samples
                    },
                    blockFrameCapacity: 17_640, bufferFrameCount: 16_384
                )
            case .quietNoise:
                TestSignal(
                    channels: TestSignal.noise(channelCount: 2, frameCount: 60_000, amplitude: 0.005, seed: 4),
                    blockFrameCapacity: 19_200, bufferFrameCount: 16_384
                )
            }
        }

        var expectedGainRange: ClosedRange<Float> {
            switch self {
            case .stereoNoiseAcrossReadBuffers: -4 ... -2
            case .manyChannelsWithShortBlocks: -2...0
            case .silence: 0...0
            case .clippingPeaks: -19 ... -17
            case .quietNoise: 12...12
            }
        }
    }
}

private struct TestSignal: Sendable {
    let channels: [[Float]]
    let blockFrameCapacity: Int
    let bufferFrameCount: Int

    /// Uniform noise from a fixed linear congruential generator, so every run measures the same samples.
    static func noise(channelCount: Int, frameCount: Int, amplitude: Float, seed: UInt64) -> [[Float]] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<channelCount).map { _ in
            (0..<frameCount).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float(state >> 40) / Float(1 << 24)
                return (unit * 2 - 1) * amplitude
            }
        }
    }
}

/// The per-sample loop that measured loudness before vDSP, reading the same buffer sizes.
private enum ScalarReference {
    static func measure(
        _ channels: [[Float]], blockFrameCapacity: Int, bufferFrameCount: Int
    ) -> (blockMeanSquares: [Double], peakAmplitude: Float) {
        let channelCount = channels.count
        let frameCount = channels.first?.count ?? 0
        var blockMeanSquares: [Double] = []
        var blockSquareSum = 0.0
        var blockFrameCount = 0
        var peakAmplitude: Float = 0
        var bufferStart = 0

        while bufferStart < frameCount {
            let frameLength = min(bufferFrameCount, frameCount - bufferStart)
            var frameOffset = 0
            while frameOffset < frameLength {
                let framesToConsume = min(blockFrameCapacity - blockFrameCount, frameLength - frameOffset)
                for channelIndex in 0..<channelCount {
                    for frameIndex in frameOffset..<(frameOffset + framesToConsume) {
                        let sample = channels[channelIndex][bufferStart + frameIndex]
                        peakAmplitude = max(peakAmplitude, abs(sample))
                        blockSquareSum += Double(sample) * Double(sample)
                    }
                }
                blockFrameCount += framesToConsume
                frameOffset += framesToConsume
                if blockFrameCount == blockFrameCapacity {
                    blockMeanSquares.append(blockSquareSum / Double(blockFrameCount * channelCount))
                    blockSquareSum = 0
                    blockFrameCount = 0
                }
            }
            bufferStart += frameLength
        }
        if blockFrameCount > 0 {
            blockMeanSquares.append(blockSquareSum / Double(blockFrameCount * channelCount))
        }
        return (blockMeanSquares, peakAmplitude)
    }
}

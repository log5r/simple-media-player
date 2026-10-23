import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct ExtendedAudioSignalTests {
    @Test
    func losslessDecodingPreservesEveryPCMFrameAndBothChannelBoundaries() throws {
        let fixture = try ExtendedAudioSignalFixture()
        defer { fixture.remove() }
        let source = try fixture.source(extension: "wv")
        defer { ExtendedAudioSource.removeCache(for: source) }
        try ExtendedAudioSource.validate(for: source)
        let readable = try ExtendedAudioSource.readableFile(for: source)
        defer { readable.release() }
        let channels = try ExtendedAudioSignalFixture.readPCM(readable.url)

        for (channel, samples) in channels.enumerated() {
            try #require(samples.count == ExtendedAudioSignalFixture.frameCount)
            let maximumError = samples.enumerated().map { frame, value in
                abs(value - ExtendedAudioSignalFixture.expectedSample(frame: frame, channel: channel))
            }.max() ?? .infinity
            #expect(maximumError < 1.0 / 32_768)
            let finiteSampleCount = samples.filter { $0.isFinite }.count
            #expect(finiteSampleCount == samples.count)
            #expect(samples.first == ExtendedAudioSignalFixture.expectedSample(frame: 0, channel: channel))
            #expect(samples.last == ExtendedAudioSignalFixture.expectedSample(
                frame: ExtendedAudioSignalFixture.frameCount - 1, channel: channel
            ))
        }
    }

    @Test
    func apeDecodingMatchesIndependentPCMReferenceForEveryFrame() throws {
        let fixture = try ExtendedAudioSignalFixture()
        defer { fixture.remove() }
        let source = try fixture.source(extension: "ape")
        defer { ExtendedAudioSource.removeCache(for: source) }
        try ExtendedAudioSource.validate(for: source)
        let readable = try ExtendedAudioSource.readableFile(for: source)
        defer { readable.release() }

        let actual = try ExtendedAudioSignalFixture.readPCM(readable.url)
        let expected = try ExtendedAudioSignalFixture.readPCM(try #require(
            ExtendedAudioSignalFixture.independentReference(for: "ape")
        ))
        let expectedFrameCount = 13_230
        #expect(actual.count == 2)
        #expect(expected.count == 2)
        for channel in 0..<2 {
            try #require(actual[channel].count == expectedFrameCount)
            try #require(expected[channel].count == expectedFrameCount)
            let maximumError = zip(actual[channel], expected[channel])
                .map { abs($0 - $1) }
                .max() ?? .infinity
            #expect(maximumError <= 1.0 / 32_768)
            #expect(actual[channel].first == expected[channel].first)
            #expect(actual[channel].last == expected[channel].last)
        }
    }

    @Test(arguments: ["mpc", "wma"])
    func lossyDecodingKeepsChannelFrequenciesEnergyAndTheFinalSection(fileExtension: String) throws {
        let fixture = try ExtendedAudioSignalFixture()
        defer { fixture.remove() }
        let source = try fixture.source(extension: fileExtension)
        defer { ExtendedAudioSource.removeCache(for: source) }
        try ExtendedAudioSource.validate(for: source)
        let readable = try ExtendedAudioSource.readableFile(for: source)
        defer { readable.release() }
        let channels = try ExtendedAudioSignalFixture.readPCM(readable.url)
        // The checked-in WMAv2 fixture contains 21 decoded 2,048-frame blocks;
        // Musepack stores the exact PCM length, including its final partial block.
        let expectedFrames = fileExtension == "wma" ? 43_008 : ExtendedAudioSignalFixture.frameCount
        for (channel, samples) in channels.enumerated() {
            try #require(samples.count == expectedFrames)
            let finiteSampleCount = samples.filter { $0.isFinite }.count
            try #require(finiteSampleCount == samples.count)
            try expectSignalEnergy(samples[8_000..<16_000])
            try expectSignalEnergy(samples[36_000..<42_000])
            try expectAutocorrelationTone(samples[8_000..<16_000], frequency: channel == 0 ? 440 : 880)
            try expectAutocorrelationTone(samples[36_000..<42_000], frequency: channel == 0 ? 1_760 : 2_200)
            let tail = samples.suffix(512)
            let meanSquare = tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)
            if fileExtension == "wma" {
                let reference = try ExtendedAudioSignalFixture.readPCM(try #require(
                    ExtendedAudioSignalFixture.independentReference(for: "wma")
                ))
                try #require(reference[channel].count == expectedFrames)
                let expectedTail = reference[channel].suffix(512)
                let expectedMeanSquare = expectedTail.reduce(0.0) {
                    $0 + Double($1) * Double($1)
                } / Double(expectedTail.count)
                #expect(abs(sqrt(meanSquare) - sqrt(expectedMeanSquare)) < 0.005)
            } else {
                #expect(sqrt(meanSquare) > 0.1)
            }
        }
    }

    private func expectSignalEnergy(_ samples: ArraySlice<Float>) throws {
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        #expect(sqrt(energy) > 0.15 && sqrt(energy) < 0.3)
    }

    private func expectAutocorrelationTone(_ samples: ArraySlice<Float>, frequency: Double) throws {
        let values = Array(samples)
        let expectedLag = ExtendedAudioSignalFixture.sampleRate / frequency
        let lowerLag = max(2, Int(floor(expectedLag)) - 2)
        let upperLag = Int(ceil(expectedLag)) + 2
        var correlations: [Double] = []
        correlations.reserveCapacity(upperLag - lowerLag + 1)
        for lag in lowerLag...upperLag {
            let overlap = values.count - lag
            var product = 0.0
            var firstEnergy = 0.0
            var secondEnergy = 0.0
            for index in 0..<overlap {
                let first = Double(values[index])
                let second = Double(values[index + lag])
                product += first * second
                firstEnergy += first * first
                secondEnergy += second * second
            }
            correlations.append(product / sqrt(firstEnergy * secondEnergy))
        }
        let peakIndex = try #require(correlations.indices.dropFirst().dropLast().max {
            correlations[$0] < correlations[$1]
        })
        let previous = correlations[peakIndex - 1]
        let peak = correlations[peakIndex]
        let next = correlations[peakIndex + 1]
        let curvature = previous - 2 * peak + next
        #expect(curvature < 0)
        let fractionalLag = Double(lowerLag + peakIndex)
            + 0.5 * (previous - next) / curvature
        let measuredFrequency = ExtendedAudioSignalFixture.sampleRate / fractionalLag
        #expect(abs(measuredFrequency - frequency) < 2)
        #expect(peak > 0.95)
    }
}

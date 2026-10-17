import Accelerate
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct PitchEffectSignalQualityTests {
    @Test(arguments: [Float(0.5), Float(1), Float(2)])
    func exportedPitchStaysIndependentOfPlaybackSpeed(rate: Float) throws {
        let source = try PitchProcessingSource(
            sampleRate: 44_100, channelCount: 1,
            samples: PitchEffectTestSignal.sine(frequency: 440, frames: 88_200)
        )
        defer { source.remove() }
        let encoder = PitchProcessingEncoder()
        let result = try TransformedAudioRenderer().render(
            sourceURL: source.url, pitchCents: -300, rate: rate, maxSampleRate: nil,
            makeEncoder: { _ in encoder }, progress: { _ in }
        )
        let expectedFrames = Int((88_200 / Double(rate)).rounded(.up))
        #expect(encoder.frameCount == expectedFrames)
        #expect(abs(result.duration - 2 / Double(rate)) < 0.000_001)
        let output = try #require(encoder.channels.first)
        let steady = output[(output.count * 2 / 5)..<(output.count * 4 / 5)]
        let measured = try PitchEffectTestSignal.measuredFrequency(steady, sampleRate: 44_100)
        let expected = 440 * pow(2, -3.0 / 12)
        #expect(abs(1200 * log2(measured / expected)) < 2)
        #expect(encoder.finishCallCount == 1)
        #expect(encoder.cancelCallCount == 0)
    }

    @Test(arguments: PitchEffectHarmonics.allCases)
    func quietHarmonicsRetainTheirExpectedFrequencyBandsAndStereoRelationship(
        signal: PitchEffectHarmonics
    ) throws {
        let input = signal.samples()
        let fixture = try PitchEffectRenderFixture()
        let output = try fixture.render(input)
        let left = Array(output[0][22_050..<(22_050 + 65_536)])
        let expectedPartials = signal.partials.map { $0 * pow(2, -3.0 / 12) }
        let outsideFraction = try PitchEffectSpectralPower.outsideFraction(left, partials: expectedPartials)

        // These bounded analytical fixtures detect new sidebands or broad noise;
        // they do not assign a perceptual score to music or compare algorithms.
        #expect(outsideFraction < signal.maximumOutsidePowerFraction)
        let energy = left.reduce(0.0) { $0 + Double($1) * Double($1) }
        #expect(sqrt(energy / Double(left.count)) > 0.01)
        let stereoError = zip(output[0], output[1]).reduce(0.0) {
            let error = Double($1.1 + 0.8 * $1.0)
            return $0 + error * error
        }
        let fullEnergy = output[0].reduce(0.0) { $0 + Double($1) * Double($1) }
        #expect(stereoError / fullEnergy < 0.000_001)
        #expect(output.allSatisfy { $0.allSatisfy { $0.isFinite } })
    }
}

nonisolated enum PitchEffectHarmonics: CaseIterable {
    case saw
    case chord

    var partials: [Double] {
        switch self {
        case .saw: (1...60).map { 110 * Double($0) }
        case .chord:
            [110.0, 138.59131548843604, 164.81377845643496].flatMap { frequency in
                (1...12).map { frequency * Double($0) }
            }
        }
    }

    var maximumOutsidePowerFraction: Double { self == .saw ? 0.001 : 0.05 }

    func samples() -> [Float] {
        let frequencies = partials
        let harmonicCount = self == .saw ? 60 : 12
        let samples = (0..<132_300).map { frame in
            frequencies.enumerated().reduce(Float.zero) { sum, partial in
                let harmonic = partial.offset % harmonicCount + 1
                let phase = 2 * .pi * partial.element * Double(frame) / 44_100
                return sum + Float(sin(phase) / Double(harmonic))
            }
        }
        let peak = samples.map { abs($0) }.max() ?? 1
        return samples.map { $0 * 0.25 / peak }
    }
}

nonisolated private enum PitchEffectSpectralPower {
    static func outsideFraction(_ samples: [Float], partials: [Double]) throws -> Double {
        let size = samples.count
        let half = size / 2
        let exponent = vDSP_Length(log2(Double(size)))
        let setup = try #require(vDSP_create_fftsetup(exponent, FFTRadix(kFFTRadix2)))
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: size)
        vDSP.multiply(samples, window, result: &windowed)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, exponent, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        var outside = 0.0
        var total = 0.0
        for (bin, value) in power.enumerated() {
            total += Double(value)
            let frequency = Double(bin) * 44_100 / Double(size)
            if partials.contains(where: { abs($0 - frequency) <= 5 }) == false { outside += Double(value) }
        }
        try #require(total > 0)
        return outside / total
    }
}

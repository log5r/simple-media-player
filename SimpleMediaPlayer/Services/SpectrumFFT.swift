import Accelerate
import Foundation

// Confined to SpectrumAnalyzer's serial analysis queue.
nonisolated final class SpectrumFFT {
    private var cachedFFTSize = 0
    private var cachedFFTWindow: [Float] = []
    private var cachedFFTSetup: FFTSetup?

    deinit {
        if let cachedFFTSetup {
            vDSP_destroy_fftsetup(cachedFFTSetup)
        }
    }

    func bandLevels(for samples: [Float], sampleRate: Float, bandCount: Int) -> [Float] {
        guard samples.count >= 2 else { return Array(repeating: 0, count: bandCount) }

        let fftSize = 1 << Int(floor(log2(Double(samples.count))))
        let halfSize = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard ensureFFTResources(fftSize: fftSize, log2n: log2n),
              let setup = cachedFFTSetup
        else {
            return Array(repeating: 0, count: bandCount)
        }

        let input = samples.count == fftSize ? samples : Array(samples.prefix(fftSize))
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP.multiply(input, cachedFFTWindow, result: &windowed)

        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        let magnitudes: [Float] = real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                var magnitudesSquared = [Float](repeating: 0, count: halfSize)
                vDSP_zvmags(&split, 1, &magnitudesSquared, 1, vDSP_Length(halfSize))

                var magnitudes = [Float](repeating: 0, count: halfSize)
                var count = Int32(halfSize)
                vvsqrtf(&magnitudes, magnitudesSquared, &count)
                var scale = Float(1.0 / Float(fftSize))
                vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfSize))
                return magnitudes
            }
        }

        let minFreq = Float(20)
        let maxFreq = min(Float(20_000), sampleRate / 2)
        return (0..<bandCount).map { band in
            let startFraction = Float(band) / Float(bandCount)
            let endFraction = Float(band + 1) / Float(bandCount)
            let startFrequency = minFreq * pow(maxFreq / minFreq, startFraction)
            let endFrequency = minFreq * pow(maxFreq / minFreq, endFraction)
            let startBin = max(1, min(halfSize - 1, Int(startFrequency / sampleRate * Float(fftSize))))
            let endBin = max(startBin + 1, min(halfSize, Int(endFrequency / sampleRate * Float(fftSize))))
            let count = endBin - startBin
            guard count > 0 else { return Float(0) }
            var peak = Float(0)
            magnitudes.withUnsafeBufferPointer { pointer in
                vDSP_maxv(pointer.baseAddress! + startBin, 1, &peak, vDSP_Length(count))
            }
            return min(1, normalizedDB(peak) * 1.18)
        }
    }

    private func ensureFFTResources(fftSize: Int, log2n: vDSP_Length) -> Bool {
        guard cachedFFTSize != fftSize || cachedFFTSetup == nil else {
            return true
        }

        if let cachedFFTSetup {
            vDSP_destroy_fftsetup(cachedFFTSetup)
        }

        cachedFFTSize = 0
        cachedFFTSetup = nil
        cachedFFTWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&cachedFFTWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        cachedFFTSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        cachedFFTSize = cachedFFTSetup == nil ? 0 : fftSize
        return cachedFFTSetup != nil
    }

    private func normalizedDB(_ value: Float) -> Float {
        let decibels = 20 * log10(max(value, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }

}

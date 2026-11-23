import Accelerate
import Foundation

// Confined to SpectrumAnalyzer's serial analysis queue.
nonisolated final class SpectrumFFT {
    private static let minimumFrequency: Float = 20
    private var cachedFFTWindow: [Float] = []
    private var cachedFFTSetup: FFTSetup?
    private var windowed: [Float] = []
    private var real: [Float] = []
    private var imaginary: [Float] = []
    private var magnitudesSquared: [Float] = []

    deinit {
        if let cachedFFTSetup {
            vDSP_destroy_fftsetup(cachedFFTSetup)
        }
    }

    // Resolve the narrowest logarithmic band across at least two FFT bins
    // to account for the Hann window's main lobe.
    // The display's update rate must not determine its frequency resolution.
    static func windowSize(sampleRate: Float, bandCount: Int) -> Int {
        let maximumFrequency = min(Float(20_000), sampleRate / 2)
        let bandWidth = minimumFrequency * (pow(maximumFrequency / minimumFrequency, 1 / Float(bandCount)) - 1)
        let samples = min(Float(131_072), max(Float(2_048), 2 * sampleRate / bandWidth))
        return 1 << Int(ceil(log2(samples)))
    }

    func bandLevels(for samples: [Float], sampleRate: Float, bandCount: Int) -> [Float] {
        guard samples.count >= 2 else { return Array(repeating: 0, count: bandCount) }

        let fftSize = 1 << Int(floor(log2(Double(samples.count))))
        let halfSize = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = fftSetup(for: fftSize, log2n: log2n) else {
            return Array(repeating: 0, count: bandCount)
        }

        vDSP.multiply(samples.suffix(fftSize), cachedFFTWindow, result: &windowed)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                vDSP_zvmags(&split, 1, &magnitudesSquared, 1, vDSP_Length(halfSize))
            }
        }

        let minFreq = Self.minimumFrequency
        let maxFreq = min(Float(20_000), sampleRate / 2)
        return (0..<bandCount).map { band in
            let startFraction = Float(band) / Float(bandCount)
            let endFraction = Float(band + 1) / Float(bandCount)
            let startFrequency = minFreq * pow(maxFreq / minFreq, startFraction)
            let endFrequency = minFreq * pow(maxFreq / minFreq, endFraction)
            // A bin belongs only to the band containing its frequency. During
            // warm-up a narrow band can have no bins; do not borrow its neighbor's.
            let startBin = max(1, min(halfSize, Int(ceil(startFrequency / sampleRate * Float(fftSize)))))
            let endBin = min(halfSize, Int(ceil(endFrequency / sampleRate * Float(fftSize))))
            let count = endBin - startBin
            guard count > 0 else { return Float(0) }
            var peakSquared = Float(0)
            magnitudesSquared.withUnsafeBufferPointer { pointer in
                vDSP_maxv(pointer.baseAddress! + startBin, 1, &peakSquared, vDSP_Length(count))
            }
            // Square root and scaling preserve order, so only the band's peak needs conversion.
            let peak = sqrt(peakSquared) / Float(fftSize)
            return min(1, Self.normalizedDB(peak) * 1.18)
        }
    }

    private func fftSetup(for fftSize: Int, log2n: vDSP_Length) -> FFTSetup? {
        if cachedFFTWindow.count == fftSize { return cachedFFTSetup }
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }

        if let cachedFFTSetup {
            vDSP_destroy_fftsetup(cachedFFTSetup)
        }
        cachedFFTSetup = setup
        cachedFFTWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&cachedFFTWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imaginary = [Float](repeating: 0, count: fftSize / 2)
        magnitudesSquared = [Float](repeating: 0, count: fftSize / 2)
        return setup
    }

    static func normalizedDB(_ value: Float) -> Float {
        let decibels = 20 * log10(max(value, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }

}

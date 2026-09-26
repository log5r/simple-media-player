import Accelerate
import AVFoundation
import Foundation

nonisolated struct AudioFrameData: Sendable {
    var bandsL: [Float]
    var bandsR: [Float]
    var peaksL: [Float]
    var peaksR: [Float]
    var rmsL: Float
    var rmsR: Float
    var peakRmsL: Float
    var peakRmsR: Float
    var isPlaying: Bool
    var currentTime: TimeInterval

    var isSilent: Bool {
        rmsL == 0 && rmsR == 0 && peakRmsL == 0 && peakRmsR == 0
            && bandsL.allSatisfy { $0 == 0 } && bandsR.allSatisfy { $0 == 0 }
            && peaksL.allSatisfy { $0 == 0 } && peaksR.allSatisfy { $0 == 0 }
    }

    static func silent(bandCount: Int = 16, currentTime: TimeInterval = 0, isPlaying: Bool = false) -> AudioFrameData {
        AudioFrameData(
            bandsL: Array(repeating: 0, count: bandCount),
            bandsR: Array(repeating: 0, count: bandCount),
            peaksL: Array(repeating: 0, count: bandCount),
            peaksR: Array(repeating: 0, count: bandCount),
            rmsL: 0,
            rmsR: 0,
            peakRmsL: 0,
            peakRmsR: 0,
            isPlaying: isPlaying,
            currentTime: currentTime
        )
    }
}

nonisolated final class SpectrumAnalyzer: @unchecked Sendable {
    // 更新頻度(低速: 約10Hz / 通常: 30Hz / 高速: 60Hz)ごとに、1回あたりの減衰量を
    // 秒あたりの視覚的な減衰速度が近くなるよう調整した定数
    private struct SmoothingParams {
        let levelRelease: Float
        let peakHoldUpdates: Int
        let peakFall: Float
        let rmsRelease: Float
    }

    private static let slowSmoothing = SmoothingParams(
        levelRelease: 0.64,
        peakHoldUpdates: 8,
        peakFall: 0.08,
        rmsRelease: 0.82
    )
    private static let normalSmoothing = SmoothingParams(
        levelRelease: 0.86,
        peakHoldUpdates: 24,
        peakFall: 0.027,
        rmsRelease: 0.94
    )
    private static let fastSmoothing = SmoothingParams(
        levelRelease: 0.90,
        peakHoldUpdates: 48,
        peakFall: 0.014,
        rmsRelease: 0.96
    )

    private let queue = DispatchQueue(label: "SimpleMediaPlayer.SpectrumAnalyzer", qos: .userInitiated)
    private let stateLock = NSLock()
    private var requestedBandCount = 16
    private var levelsL = Array(repeating: Float(0), count: 16)
    private var levelsR = Array(repeating: Float(0), count: 16)
    private var peaksL = Array(repeating: Float(0), count: 16)
    private var peaksR = Array(repeating: Float(0), count: 16)
    private var peakAgesL = Array(repeating: 0, count: 16)
    private var peakAgesR = Array(repeating: 0, count: 16)
    private var rmsL: Float = 0
    private var rmsR: Float = 0
    private var peakRmsL: Float = 0
    private var peakRmsR: Float = 0
    private var rmsPeakAgeL = 0
    private var rmsPeakAgeR = 0
    private var analysisInFlight = false
    private var playbackActive = false
    private var generation = 0
    private var lastAcceptedAnalysisTime = TimeInterval.zero
    private let minimumAnalysisInterval = 1.0 / 60.0
    private var responseMode = VisualizerResponseMode.normal
    private var chunkHistoryL: [Float] = []
    private var chunkHistoryR: [Float] = []
    private let chunkWindowSize = 2048
    private var cachedFFTSize = 0
    private var cachedFFTWindow: [Float] = []
    private var cachedFFTSetup: FFTSetup?
    private var lastFrameTime: TimeInterval = 0

    var onFrame: (@MainActor (AudioFrameData) -> Void)?

    func setPlaybackActive(_ active: Bool, currentTime: TimeInterval) {
        let generation = stateLock.withLock {
            self.generation += 1
            playbackActive = active
            lastAcceptedAnalysisTime = 0
            return self.generation
        }
        queue.async {
            guard self.isCurrent(generation) else { return }
            self.chunkHistoryL.removeAll()
            self.chunkHistoryR.removeAll()
            if active == false {
                self.decayUntilSilent(
                    currentTime: currentTime,
                    generation: generation,
                    deadline: ProcessInfo.processInfo.systemUptime + 3
                )
            }
        }
    }

    deinit {
        if let cachedFFTSetup {
            vDSP_destroy_fftsetup(cachedFFTSetup)
        }
    }

    func setResponseMode(_ mode: VisualizerResponseMode) {
        queue.async {
            guard mode != self.responseMode else { return }
            self.responseMode = mode
            self.chunkHistoryL.removeAll()
            self.chunkHistoryR.removeAll()
        }
    }

    func setBandCount(_ count: Int?) {
        queue.async {
            let newCount = max(1, count ?? 16)
            guard newCount != self.requestedBandCount else { return }
            self.requestedBandCount = newCount
            self.levelsL = Array(repeating: 0, count: newCount)
            self.levelsR = Array(repeating: 0, count: newCount)
            self.peaksL = Array(repeating: 0, count: newCount)
            self.peaksR = Array(repeating: 0, count: newCount)
            self.peakAgesL = Array(repeating: 0, count: newCount)
            self.peakAgesR = Array(repeating: 0, count: newCount)
            let state = self.stateLock.withLock { (self.playbackActive, self.generation) }
            self.emit(currentTime: self.lastFrameTime, isPlaying: state.0, generation: state.1)
        }
    }

    func analyze(_ buffer: AVAudioPCMBuffer, currentTime: TimeInterval, isPlaying: Bool) {
        // Paused taps can still deliver the reverb tail. They need neither PCM copies nor FFT.
        guard isPlaying, let generation = beginAnalysisIfNeeded() else { return }
        guard let channels = buffer.floatChannelData else {
            finishAnalysis()
            return
        }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            finishAnalysis()
            return
        }

        let left = Array(UnsafeBufferPointer(start: channels[0], count: frameLength))
        let rightIndex = buffer.format.channelCount > 1 ? 1 : 0
        let right = Array(UnsafeBufferPointer(start: channels[rightIndex], count: frameLength))
        let sampleRate = Float(buffer.format.sampleRate)

        queue.async {
            defer { self.finishAnalysis() }
            guard self.isCurrent(generation) else { return }
            let mode = self.responseMode
            if mode != .slow {
                self.scheduleChunkedAnalysis(
                    left: left,
                    right: right,
                    sampleRate: sampleRate,
                    currentTime: currentTime,
                    isPlaying: isPlaying,
                    mode: mode,
                    generation: generation
                )
                return
            }
            let params = Self.slowSmoothing
            let newL = self.bandLevels(for: left, sampleRate: sampleRate, bandCount: self.requestedBandCount)
            let newR = self.bandLevels(for: right, sampleRate: sampleRate, bandCount: self.requestedBandCount)
            self.levelsL = zip(newL, self.levelsL).map {
                $0 > $1 ? min(1, $0 * 1.12) : max($0, $1 * params.levelRelease)
            }
            self.levelsR = zip(newR, self.levelsR).map {
                $0 > $1 ? min(1, $0 * 1.12) : max($0, $1 * params.levelRelease)
            }
            self.updatePeaks(levels: self.levelsL, peaks: &self.peaksL, ages: &self.peakAgesL, params: params)
            self.updatePeaks(levels: self.levelsR, peaks: &self.peaksR, ages: &self.peakAgesR, params: params)
            self.updateRMS(left: left, right: right, params: params)
            self.emit(currentTime: currentTime, isPlaying: isPlaying, generation: generation)
        }
    }

    // オーディオタップは約100ms分(4800フレーム)単位でしか届かないため、
    // 通常・高速モードでは指定fps分のチャンクに分割し、実再生タイミングに
    // 合わせて時間差で解析・発光する。
    private func scheduleChunkedAnalysis(
        left: [Float],
        right: [Float],
        sampleRate: Float,
        currentTime: TimeInterval,
        isPlaying: Bool,
        mode: VisualizerResponseMode,
        generation: Int
    ) {
        let updateRate = mode.framesPerSecond
        let chunkFrames = max(1, Int(Double(sampleRate) / updateRate))
        let chunkCount = max(1, left.count / chunkFrames)
        for index in 0..<chunkCount {
            let start = index * chunkFrames
            let end = index == chunkCount - 1 ? left.count : start + chunkFrames
            let chunkL = Array(left[start..<end])
            let chunkR = Array(right[start..<end])
            let chunkTime = currentTime + Double(start) / Double(sampleRate)
            queue.asyncAfter(deadline: .now() + Double(index) / updateRate) {
                guard self.responseMode == mode, self.isCurrent(generation) else { return }
                self.processChunk(
                    chunkL: chunkL,
                    chunkR: chunkR,
                    sampleRate: sampleRate,
                    currentTime: chunkTime,
                    isPlaying: isPlaying,
                    params: Self.smoothingParams(for: mode),
                    generation: generation
                )
            }
        }
    }

    private func processChunk(
        chunkL: [Float],
        chunkR: [Float],
        sampleRate: Float,
        currentTime: TimeInterval,
        isPlaying: Bool,
        params: SmoothingParams,
        generation: Int
    ) {
        appendChunkHistory(&chunkHistoryL, chunkL)
        appendChunkHistory(&chunkHistoryR, chunkR)
        let newL = bandLevels(for: chunkHistoryL, sampleRate: sampleRate, bandCount: requestedBandCount)
        let newR = bandLevels(for: chunkHistoryR, sampleRate: sampleRate, bandCount: requestedBandCount)
        levelsL = zip(newL, levelsL).map { $0 > $1 ? min(1, $0 * 1.12) : max($0, $1 * params.levelRelease) }
        levelsR = zip(newR, levelsR).map { $0 > $1 ? min(1, $0 * 1.12) : max($0, $1 * params.levelRelease) }
        updatePeaks(levels: levelsL, peaks: &peaksL, ages: &peakAgesL, params: params)
        updatePeaks(levels: levelsR, peaks: &peaksR, ages: &peakAgesR, params: params)
        updateRMS(left: chunkL, right: chunkR, params: params)
        emit(currentTime: currentTime, isPlaying: isPlaying, generation: generation)
    }

    private func appendChunkHistory(_ history: inout [Float], _ chunk: [Float]) {
        history.append(contentsOf: chunk)
        if history.count > chunkWindowSize {
            history.removeFirst(history.count - chunkWindowSize)
        }
    }

    private static func smoothingParams(for mode: VisualizerResponseMode) -> SmoothingParams {
        switch mode {
        case .slow: slowSmoothing
        case .normal: normalSmoothing
        case .fast: fastSmoothing
        }
    }

    private func beginAnalysisIfNeeded() -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        guard playbackActive,
              analysisInFlight == false,
              now - lastAcceptedAnalysisTime >= minimumAnalysisInterval else {
            return nil
        }

        analysisInFlight = true
        lastAcceptedAnalysisTime = now
        return generation
    }

    private func finishAnalysis() {
        stateLock.lock()
        analysisInFlight = false
        stateLock.unlock()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        stateLock.withLock { self.generation == generation }
    }

    private func decayUntilSilent(currentTime: TimeInterval, generation: Int, deadline: TimeInterval) {
        guard isCurrent(generation) else { return }
        let params = Self.smoothingParams(for: responseMode)
        let release = Float(pow(0.64, 30 / responseMode.framesPerSecond))
        func released(_ value: Float) -> Float {
            let result = value * release
            return result < 0.001 ? 0 : result
        }
        levelsL = levelsL.map(released)
        levelsR = levelsR.map(released)
        updatePeaks(levels: levelsL, peaks: &peaksL, ages: &peakAgesL, params: params)
        updatePeaks(levels: levelsR, peaks: &peaksR, ages: &peakAgesR, params: params)
        rmsL = released(rmsL)
        rmsR = released(rmsR)
        updateRMSPeak(params: params)
        peaksL = peaksL.map { $0 < 0.001 ? 0 : $0 }
        peaksR = peaksR.map { $0 < 0.001 ? 0 : $0 }
        peakRmsL = peakRmsL < 0.001 ? 0 : peakRmsL
        peakRmsR = peakRmsR < 0.001 ? 0 : peakRmsR
        if ProcessInfo.processInfo.systemUptime >= deadline {
            levelsL = Array(repeating: 0, count: requestedBandCount)
            levelsR = levelsL
            peaksL = levelsL
            peaksR = levelsL
            rmsL = 0
            rmsR = 0
            peakRmsL = 0
            peakRmsR = 0
        }
        let frame = emit(currentTime: currentTime, isPlaying: false, generation: generation)
        guard frame.isSilent == false else { return }
        queue.asyncAfter(deadline: .now() + 1 / responseMode.framesPerSecond) { [weak self] in
            self?.decayUntilSilent(currentTime: currentTime, generation: generation, deadline: deadline)
        }
    }

    private func bandLevels(for samples: [Float], sampleRate: Float, bandCount: Int) -> [Float] {
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

    private func updatePeaks(levels: [Float], peaks: inout [Float], ages: inout [Int], params: SmoothingParams) {
        for index in levels.indices {
            if levels[index] >= peaks[index] {
                peaks[index] = levels[index]
                ages[index] = 0
            } else if ages[index] > params.peakHoldUpdates {
                peaks[index] = max(levels[index], peaks[index] - params.peakFall)
            } else {
                ages[index] += 1
            }
        }
    }

    private func updateRMS(left: [Float], right: [Float], params: SmoothingParams) {
        let newL = normalizedDB(vDSP.rootMeanSquare(left))
        let newR = normalizedDB(vDSP.rootMeanSquare(right))
        rmsL = newL > rmsL ? newL : max(newL, rmsL * params.rmsRelease)
        rmsR = newR > rmsR ? newR : max(newR, rmsR * params.rmsRelease)
        updateRMSPeak(params: params)
    }

    private func updateRMSPeak(params: SmoothingParams) {
        if rmsL >= peakRmsL {
            peakRmsL = rmsL
            rmsPeakAgeL = 0
        } else if rmsPeakAgeL > params.peakHoldUpdates {
            peakRmsL = max(rmsL, peakRmsL - params.peakFall)
        } else {
            rmsPeakAgeL += 1
        }

        if rmsR >= peakRmsR {
            peakRmsR = rmsR
            rmsPeakAgeR = 0
        } else if rmsPeakAgeR > params.peakHoldUpdates {
            peakRmsR = max(rmsR, peakRmsR - params.peakFall)
        } else {
            rmsPeakAgeR += 1
        }
    }

    @discardableResult
    private func emit(currentTime: TimeInterval, isPlaying: Bool, generation: Int) -> AudioFrameData {
        lastFrameTime = currentTime
        let frame = AudioFrameData(
            bandsL: levelsL,
            bandsR: levelsR,
            peaksL: peaksL,
            peaksR: peaksR,
            rmsL: rmsL,
            rmsR: rmsR,
            peakRmsL: peakRmsL,
            peakRmsR: peakRmsR,
            isPlaying: isPlaying,
            currentTime: currentTime
        )
        Task { @MainActor in
            guard self.isCurrent(generation) else { return }
            self.onFrame?(frame)
        }
        return frame
    }
}

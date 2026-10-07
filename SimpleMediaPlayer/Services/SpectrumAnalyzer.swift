import Accelerate
import AVFoundation
import Foundation
import Synchronization

nonisolated final class SpectrumAnalyzer: @unchecked Sendable {
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
    // Read by the real-time video tap without entering stateLock.
    private let videoAnalysisGeneration = Atomic<Int>(0)
    private let videoSamples = VideoSpectrumAccumulator()

    var realtimeVideoGeneration: Int {
        videoAnalysisGeneration.load(ordering: .acquiring)
    }
    private var lastAcceptedAnalysisTime = TimeInterval.zero
    private let minimumAnalysisInterval = 1.0 / 60.0
    private var responseMode = VisualizerResponseMode.normal
    private var chunkHistoryL: [Float] = []
    private var chunkHistoryR: [Float] = []
    private let chunkWindowSize = 2048
    private let fft = SpectrumFFT()
    private var lastFrameTime: TimeInterval = 0

    var onFrame: (@MainActor (AudioFrameData) -> Void)?

    func setPlaybackActive(_ active: Bool, currentTime: TimeInterval) {
        let generation = stateLock.withLock {
            self.generation += 1
            playbackActive = active
            videoAnalysisGeneration.store(active ? self.generation : 0, ordering: .releasing)
            lastAcceptedAnalysisTime = 0
            return self.generation
        }
        queue.async {
            guard self.isCurrent(generation) else { return }
            self.chunkHistoryL.removeAll()
            self.chunkHistoryR.removeAll()
            self.videoSamples.reset()
            if active { self.resetAnalysisState() }
            if active == false {
                self.decayUntilSilent(
                    currentTime: currentTime,
                    generation: generation,
                    deadline: ProcessInfo.processInfo.systemUptime + 3
                )
            }
        }
    }

    func setResponseMode(_ mode: VisualizerResponseMode) {
        queue.async {
            guard mode != self.responseMode else { return }
            self.responseMode = mode
            self.videoSamples.reset()
            self.chunkHistoryL.removeAll()
            self.chunkHistoryR.removeAll()
        }
    }

    func setBandCount(_ count: Int?) {
        queue.async {
            let newCount = max(1, count ?? 16)
            guard newCount != self.requestedBandCount else { return }
            self.requestedBandCount = newCount
            self.resetAnalysisState()
            let state = self.stateLock.withLock { (self.playbackActive, self.generation) }
            self.emit(currentTime: self.lastFrameTime, isPlaying: state.0, generation: state.1)
        }
    }

    private func processChunk(
        chunkL: [Float],
        chunkR: [Float],
        sampleRate: Float,
        currentTime: TimeInterval,
        isPlaying: Bool,
        params: SpectrumSmoothing,
        generation: Int,
        isSourceCurrent: (@Sendable () -> Bool)? = nil,
        usesHistory: Bool = true
    ) {
        var historyL = usesHistory ? chunkHistoryL : []
        var historyR = usesHistory ? chunkHistoryR : []
        if usesHistory {
            appendChunkHistory(&historyL, chunkL)
            appendChunkHistory(&historyR, chunkR)
        }
        let newL = fft.bandLevels(for: usesHistory ? historyL : chunkL,
                                  sampleRate: sampleRate, bandCount: requestedBandCount)
        let newR = fft.bandLevels(for: usesHistory ? historyR : chunkR,
                                  sampleRate: sampleRate, bandCount: requestedBandCount)
        let rms = (left: normalizedDB(vDSP.rootMeanSquare(chunkL)), right: normalizedDB(vDSP.rootMeanSquare(chunkR)))
        // FFT and RMS run without stateLock. Revalidate before applying their result.
        guard isCurrent(generation), isSourceCurrent?() != false else { return }
        if usesHistory {
            chunkHistoryL = historyL
            chunkHistoryR = historyR
        }
        levelsL = zip(newL, levelsL).map { $0 > $1 ? min(1, $0 * 1.12) : max($0, $1 * params.levelRelease) }
        levelsR = zip(newR, levelsR).map { $0 > $1 ? min(1, $0 * 1.12) : max($0, $1 * params.levelRelease) }
        params.updatePeaks(levels: levelsL, peaks: &peaksL, ages: &peakAgesL)
        params.updatePeaks(levels: levelsR, peaks: &peaksR, ages: &peakAgesR)
        updateRMS(levels: rms, params: params)
        emit(
            currentTime: currentTime, isPlaying: isPlaying, generation: generation,
            isSourceCurrent: isSourceCurrent
        )
    }

    private func resetAnalysisState() {
        chunkHistoryL.removeAll()
        chunkHistoryR.removeAll()
        levelsL = Array(repeating: 0, count: requestedBandCount)
        levelsR = levelsL
        peaksL = levelsL
        peaksR = levelsL
        peakAgesL = Array(repeating: 0, count: requestedBandCount)
        peakAgesR = peakAgesL
        rmsL = 0
        rmsR = 0
        peakRmsL = 0
        peakRmsR = 0
        rmsPeakAgeL = 0
        rmsPeakAgeR = 0
    }

    private func appendChunkHistory(_ history: inout [Float], _ chunk: [Float]) {
        history.append(contentsOf: chunk)
        if history.count > chunkWindowSize {
            history.removeFirst(history.count - chunkWindowSize)
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
        let params = SpectrumSmoothing.parameters(for: responseMode)
        let release = Float(pow(0.64, 30 / responseMode.framesPerSecond))
        func released(_ value: Float) -> Float {
            let result = value * release
            return result < 0.001 ? 0 : result
        }
        levelsL = levelsL.map(released)
        levelsR = levelsR.map(released)
        params.updatePeaks(levels: levelsL, peaks: &peaksL, ages: &peakAgesL)
        params.updatePeaks(levels: levelsR, peaks: &peaksR, ages: &peakAgesR)
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

    private func normalizedDB(_ value: Float) -> Float {
        let decibels = 20 * log10(max(value, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }

    private func updateRMS(levels: (left: Float, right: Float), params: SpectrumSmoothing) {
        rmsL = levels.left > rmsL ? levels.left : max(levels.left, rmsL * params.rmsRelease)
        rmsR = levels.right > rmsR ? levels.right : max(levels.right, rmsR * params.rmsRelease)
        updateRMSPeak(params: params)
    }

    private func updateRMSPeak(params: SpectrumSmoothing) {
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
    private func emit(
        currentTime: TimeInterval,
        isPlaying: Bool,
        generation: Int,
        isSourceCurrent: (@Sendable () -> Bool)? = nil
    ) -> AudioFrameData {
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
            guard self.isCurrent(generation), isSourceCurrent?() != false else { return }
            self.onFrame?(frame)
        }
        return frame
    }
}

// Input scheduling stays separate from the shared spectral and meter state.
nonisolated extension SpectrumAnalyzer {
    func makeVideoSampleTimer(for ring: VideoAudioSampleRing) -> DispatchSourceTimer {
        // Drain on the FFT queue: if analysis falls behind, the ring fills and drops
        // visualization input instead of accumulating an unbounded dispatch backlog.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak ring] in
            guard let ring else { return }
            ring.drain { batch in
                self.analyzeVideoSamples(batch) { ring.isCurrent(batch) }
            }
        }
        return timer
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
            self.processChunk(
                chunkL: left, chunkR: right, sampleRate: sampleRate,
                currentTime: currentTime, isPlaying: isPlaying,
                params: .slow, generation: generation, usesHistory: false
            )
        }
    }

    // Called only by the ring's consumer. Small tap buffers are accumulated into
    // full 10/30/60 Hz chunks; large buffers are emitted at playback cadence.
    func analyzeVideoSamples(
        _ batch: VideoAudioSampleRing.Batch,
        isSourceCurrent: @escaping @Sendable () -> Bool
    ) {
        queue.async {
            guard isSourceCurrent(), self.isCurrent(batch.analysisGeneration) else { return }
            let mode = self.responseMode
            let result = self.videoSamples.append(batch, mode: mode)
            if result.didReset { self.resetAnalysisState() }
            let revision = self.videoSamples.revision
            for chunk in result.chunks {
                self.queue.asyncAfter(deadline: .now() + max(0, chunk.time - batch.time)) {
                    guard isSourceCurrent(), self.isCurrent(batch.analysisGeneration),
                          self.responseMode == mode, self.videoSamples.revision == revision else { return }
                    self.processChunk(
                        chunkL: chunk.left, chunkR: chunk.right, sampleRate: Float(batch.sampleRate),
                        currentTime: chunk.time, isPlaying: true,
                        params: SpectrumSmoothing.parameters(for: mode), generation: batch.analysisGeneration,
                        isSourceCurrent: isSourceCurrent
                    )
                }
            }
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
                    params: SpectrumSmoothing.parameters(for: mode),
                    generation: generation
                )
            }
        }
    }
}

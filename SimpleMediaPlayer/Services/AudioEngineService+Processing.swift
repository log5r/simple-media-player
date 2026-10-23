import AVFoundation
import Foundation

nonisolated extension AudioEngineService {
    // 設定を再生中に切り替えても段差ノイズが出ないよう、補正量を短くランプさせる。
    // controlQueue 上でのみ呼ぶこと。
    func applyLoudnessGain(_ decibels: Float) {
        let target = max(
            AudioLoudnessNormalizer.minimumGainDecibels,
            min(AudioLoudnessNormalizer.maximumGainDecibels, decibels)
        )
        let start = loudnessGain.bypass ? 0 : loudnessGain.globalGain
        loudnessGain.bypass = false
        let steps = 10
        for step in 1...steps {
            loudnessGain.globalGain = start + (target - start) * Float(step) / Float(steps)
            if playerNode.isPlaying {
                usleep(5000)
            }
        }
        loudnessGain.bypass = target == 0
    }

    func configureGraphicEqualizerBands() {
        for (band, parameters) in zip(
            graphicEQ.bands,
            zip(EqualizerSettings.bandFrequencies, EqualizerSettings.bandBandwidths)
        ) {
            let (frequency, bandwidth) = parameters
            band.filterType = .parametric
            band.frequency = Float(frequency)
            band.bandwidth = bandwidth
            band.bypass = false
        }
    }

    func applyEqualizer(_ settings: EqualizerSettings) {
        for (band, gain) in zip(graphicEQ.bands, settings.bandGains) {
            band.gain = EqualizerSettings.clampedGain(gain)
            band.bypass = false
        }
        graphicEQ.globalGain = EqualizerSettings.clampedGain(settings.preampDecibels)
        graphicEQ.bypass = settings.isEnabled == false

        let wetDryMix = EqualizerSettings.clampedReverbWetDryMix(settings.reverbWetDryMix)
        if loadedReverbPreset != settings.reverbPreset {
            reverb.loadFactoryPreset(settings.reverbPreset.avAudioUnitPreset)
            loadedReverbPreset = settings.reverbPreset
        }
        reverb.wetDryMix = wetDryMix
        reverb.bypass = settings.isEnabled == false || wetDryMix == 0
    }

    // ピッチ処理の後でフェードする。入力側の音量を落とすだけでは、DSPの遅延分が
    // 排出される前にresetして波形を切ることになる。controlQueue 上でのみ呼ぶこと。
    func stopWithFadeOut() {
        guard playerNode.isPlaying else {
            playerNode.stop()
            resetPitchProcessors()
            return
        }
        let original = fadeMixer.outputVolume
        if original > 0 {
            let steps = 10
            for step in 1...steps {
                fadeMixer.outputVolume = original * Float(steps - step) / Float(steps)
                waitForFadeStep(6000)
            }
            // 最後の音量変更(→0)のミキサー内部平滑が完了するのを待ってから止める。
            // 待ちが足りないと小さな段差が残って微かにプツッと鳴る
            waitForFadeStep(15000)
        }
        playerNode.stop()
        resetPitchProcessors()
        fadeMixer.outputVolume = original
    }

    func resetPitchProcessors() {
        timePitch.reset()
        pitchEffect.reset()
    }

    var playbackProcessingLatency: TimeInterval {
        // TimePitch buffers real-time audio even in bypass; offline rendering can report zero.
        max(0, timePitch.latency + pitchEffect.latency + outputProtection.latency)
    }

    func performPendingSeek(for requestID: UUID, seekID: UUID? = nil) {
        stateLock.lock()
        guard activeLoadID == requestID,
              let request = pendingSeek,
              request.loadID == requestID,
              seekID == nil || request.seekID == seekID else {
            stateLock.unlock()
            return
        }
        if audioFile != nil { pendingSeek = nil }
        stateLock.unlock()
        guard let audioFile else {
            if preparationTask != nil {
                playWhenReady = request.autoPlay
                if request.autoPlay == false { suspendAfterTail() }
            }
            return
        }
        playWhenReady = false
        let target = max(0, min(audioFile.length, AVAudioFramePosition(request.time * sampleRate)))
        seekFrame = target
        setDisplayClock(playing: false)
        invalidateScheduledSegment()
        stopWithFadeOut()
        resetDisplayClock(to: Double(target) / sampleRate)
        if request.autoPlay {
            performPlay()
        } else {
            loudnessNormalization.cancel()
            suspendAfterTail()
        }
    }

    func schedule(file: AVAudioFile, from frame: AVAudioFramePosition) {
        let remaining = AVAudioFrameCount(max(0, file.length - frame))
        guard remaining > 0 else {
            notifyFinished()
            return
        }
        startFrame = frame
        seekFrame = frame
        resetDisplayClock(to: Double(frame) / sampleRate, latency: playbackProcessingLatency)
        // 世代番号で stop 済みセグメントの完了コールバックを無効化する。
        // 世代の比較を controlQueue 上に寄せることで stop() との競合も排除する
        scheduleGeneration += 1
        let generation = scheduleGeneration
        playerNode.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: remaining,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            self.controlQueue.async {
                guard generation == self.scheduleGeneration, self.engine.isRunning else { return }
                self.finishPlayback(at: file.length)
            }
        }
    }

    func invalidateScheduledSegment() {
        scheduleGeneration += 1
    }

    func frame(for time: TimeInterval) -> AVAudioFramePosition {
        AVAudioFramePosition(max(0, min(duration, time)) * sampleRate)
    }

    // 実ファイルサイズ ÷ 再生時間からの概算(可変ビットレートやロスレスでも実測値になる)
    static func estimatedBitrateKbps(url: URL, duration: TimeInterval) -> Int {
        guard duration > 0,
              let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              fileSize > 0
        else {
            return 0
        }
        return Int((Double(fileSize) * 8 / duration / 1000).rounded())
    }

    func reportError(_ error: Error, for requestID: UUID? = nil, playbackRequestID: UUID? = nil) {
        let message = error.localizedDescription
        Task { @MainActor in
            if let requestID, self.isActiveLoad(requestID) == false { return }
            if let playbackRequestID, self.isActivePlaybackRequest(playbackRequestID) == false { return }
            self.onError?(message)
        }
    }

    func isActiveLoad(_ requestID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeLoadID == requestID
    }

    func isActivePlaybackRequest(_ requestID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activePlaybackRequestID == requestID
    }

    // stateLock を保持した状態で呼ぶこと
    func renewPlaybackRequestLocked() -> UUID {
        let requestID = UUID()
        activePlaybackRequestID = requestID
        return requestID
    }

    func installTap() {
        outputProtection.outputNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let clock = self.advanceDisplayClock(byFrames: buffer.frameLength, sampleRate: buffer.format.sampleRate)
            self.analyzer.analyze(buffer, currentTime: clock.time, isPlaying: clock.isPlaying)
        }
    }

    func setCachedDuration(_ value: TimeInterval) {
        stateLock.lock()
        cachedDuration = value
        stateLock.unlock()
    }

    func setDisplayClock(playing: Bool) {
        stateLock.lock()
        displayIsPlaying = playing
        stateLock.unlock()
    }

    func resetDisplayClock(to time: TimeInterval, latency: TimeInterval = 0) {
        stateLock.lock()
        displayBaseTime = time
        displayElapsedTime = 0
        displayLatencyRemaining = latency
        stateLock.unlock()
    }

    func advanceDisplayClock(
        byFrames frames: AVAudioFrameCount,
        sampleRate: Double
    ) -> (time: TimeInterval, isPlaying: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if displayIsPlaying, sampleRate > 0 {
            let renderedDuration = Double(frames) / sampleRate
            let delayedDuration = min(displayLatencyRemaining, renderedDuration)
            displayLatencyRemaining -= delayedDuration
            displayElapsedTime = min(
                max(0, cachedDuration - displayBaseTime),
                displayElapsedTime + (renderedDuration - delayedDuration) * displayRate
            )
        }
        return (displayBaseTime + displayElapsedTime, displayIsPlaying)
    }
}

private extension EqualizerReverbPreset {
    nonisolated var avAudioUnitPreset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom:
            .smallRoom
        case .mediumRoom:
            .mediumRoom
        case .largeHall:
            .largeHall2
        }
    }
}

extension AudioEngineService: AudioPlaybackControlling {}

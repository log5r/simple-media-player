import AVFoundation
import Foundation

nonisolated extension AudioEngineService {
    var loudnessNormalization: AudioLoudnessNormalization {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        if let loudnessNormalizationStorage { return loudnessNormalizationStorage }
        let normalization = AudioLoudnessNormalization(controlQueue: controlQueue) { [weak self] gain in
            self?.applyLoudnessGain(gain)
        }
        loudnessNormalizationStorage = normalization
        return normalization
    }

    // 初回構築も再構築も controlQueue 上。後続の load / play より先に実行する。
    func buildEngineGraph() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.attach(pitchEffect.node)
        engine.attach(fadeMixer)
        engine.attach(loudnessGain)
        engine.attach(graphicEQ)
        engine.attach(reverb)
        outputProtection.attach(to: engine)
        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: pitchEffect.node, format: nil)
        engine.connect(pitchEffect.node, to: fadeMixer, format: nil)
        engine.connect(fadeMixer, to: loudnessGain, format: nil)
        engine.connect(loudnessGain, to: graphicEQ, format: nil)
        engine.connect(graphicEQ, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        loudnessGain.bypass = true
        timePitch.pitch = 0
        timePitch.bypass = timePitch.rate == 1
        configureGraphicEqualizerBands()
        applyEqualizer(currentEqualizerSettings)
        observeEngineConfiguration()
    }

    // Transport actions use this output clock too. Subtracting the latest rate times
    // the DSP delay from playerTime would jump after a rate change or route loss.
    var currentTime: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return displayBaseTime + displayElapsedTime
    }

    var duration: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedDuration
    }

    func setVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        controlQueue.async {
            self.playerNode.volume = clamped
        }
    }

    func setPitchCents(_ cents: Float) {
        let clamped = max(-2400, min(2400, cents))
        controlQueue.async {
            self.pitchEffect.pitchCents = clamped
        }
    }

    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.25, min(4.0, rate))
        controlQueue.async {
            self.timePitch.rate = clamped
            self.timePitch.bypass = clamped == 1
            self.stateLock.withLock { self.displayRate = Double(clamped) }
        }
    }

    func setVolumeNormalizationEnabled(_ enabled: Bool) {
        controlQueue.async {
            self.loudnessNormalization.setEnabled(enabled)
        }
    }

    func setEqualizer(_ settings: EqualizerSettings) {
        controlQueue.async {
            self.currentEqualizerSettings = settings
            self.applyEqualizer(settings)
        }
    }

    func load(url: URL) {
        let requestID = UUID()
        // キュー投入前に旧曲のシークを消し、このload後に要求されたシークは残す。
        stateLock.lock()
        pendingSeek = nil
        activeLoadID = requestID
        let playbackRequestID = renewPlaybackRequestLocked()
        stateLock.unlock()
        controlQueue.async {
            self.appliedPlaybackRequestID = playbackRequestID
            self.preparationTask?.cancel()
            self.loadGeneration += 1
            let generation = self.loadGeneration
            // 旧曲のフェードアウトと並行して新しいファイルを開く。結果の適用は controlQueue に積むため
            // このブロックの後に実行され、そこで世代と要求 ID を照合する
            self.preparationTask = Task.detached(
                executorPreference: BlockingWorkExecutor.shared, priority: .userInitiated
            ) {
                await ExtendedAudioSource.withCancellableCacheWaits {
                    self.prepareAudio(url: url, generation: generation, requestID: requestID)
                }
            }
            self.performStop(reset: true)
            self.releaseLoadedAudio()
            self.currentURL = url
            self.playWhenReady = false
            self.setCachedDuration(0)
        }
    }

    func prepareAudio(url: URL, generation: Int, requestID: UUID) {
        do {
            let readableFile = try openReadableFile(url)
            do {
                try Task.checkCancellation()
                let file = try AVAudioFile(forReading: readableFile.url)
                try Task.checkCancellation()
                controlQueue.async {
                    self.acceptPreparedAudio(file, readableFile: readableFile, url: url,
                                             generation: generation, requestID: requestID)
                }
            } catch {
                readableFile.release()
                throw error
            }
        } catch is CancellationError {
            controlQueue.async {
                guard generation == self.loadGeneration, self.isActiveLoad(requestID) else { return }
                self.finishPreparationWithoutAudio()
            }
        } catch {
            controlQueue.async {
                guard generation == self.loadGeneration, self.isActiveLoad(requestID) else { return }
                self.finishPreparationWithoutAudio()
                self.reportError(error, for: requestID)
            }
        }
    }

    func acceptPreparedAudio(
        _ file: AVAudioFile, readableFile: ExtendedAudioCache.ReadableFile,
        url: URL, generation: Int, requestID: UUID
    ) {
        guard generation == loadGeneration, isActiveLoad(requestID) else {
            readableFile.release()
            return
        }
        preparationTask = nil
        currentReadableFile = readableFile
        audioFile = file
        sampleRate = file.fileFormat.sampleRate
        loudnessNormalization.load(url)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        setCachedDuration(duration)
        let bitrateKbps = Self.estimatedBitrateKbps(url: url, duration: duration)
        let formatInfo = MediaFormatInfo(
            sampleRateHz: file.fileFormat.sampleRate,
            bitrateKbps: bitrateKbps > 0 ? bitrateKbps : nil
        )
        Task { @MainActor in
            guard self.isActiveLoad(requestID) else { return }
            self.onFormatLoaded?(duration, formatInfo)
        }
        performPendingSeek(for: requestID)
        if playWhenReady {
            playWhenReady = false
            performPlay()
        }
    }

    func releaseLoadedAudio() {
        audioFile = nil
        currentReadableFile?.release()
        currentReadableFile = nil
        currentURL = nil
    }

    func play() {
        stateLock.lock()
        if let request = pendingSeek {
            pendingSeek = PendingSeek(
                time: request.time,
                autoPlay: true,
                loadID: request.loadID,
                seekID: request.seekID
            )
        }
        let playbackRequestID = renewPlaybackRequestLocked()
        stateLock.unlock()
        controlQueue.async {
            self.appliedPlaybackRequestID = playbackRequestID
            if self.audioFile == nil, self.preparationTask != nil {
                self.playWhenReady = true
            } else {
                self.performPlay()
            }
        }
    }

    func pause() {
        stateLock.lock()
        if let request = pendingSeek {
            pendingSeek = PendingSeek(
                time: request.time,
                autoPlay: false,
                loadID: request.loadID,
                seekID: request.seekID
            )
        }
        let playbackRequestID = renewPlaybackRequestLocked()
        stateLock.unlock()
        controlQueue.async {
            self.appliedPlaybackRequestID = playbackRequestID
            self.playWhenReady = false
            self.loudnessNormalization.cancel()
            self.seekFrame = self.frame(for: self.currentTime)
            self.setDisplayClock(playing: false)
            self.resetDisplayClock(to: Double(self.seekFrame) / self.sampleRate)
            self.invalidateScheduledSegment()
            self.stopWithFadeOut()
            self.suspendAfterTail()
        }
    }

    func stop(reset: Bool) {
        stateLock.lock()
        pendingSeek = nil
        let playbackRequestID = renewPlaybackRequestLocked()
        stateLock.unlock()
        controlQueue.async {
            self.appliedPlaybackRequestID = playbackRequestID
            self.playWhenReady = false
            self.performStop(reset: reset)
        }
    }

    // 動画への切り替えでは旧音声の残響を待たずにエンジンを停止する。
    // 旧音声のファイルも解放し、次の load / play で再生を開始する。
    func suspend() {
        stateLock.lock()
        pendingSeek = nil
        activeLoadID = UUID()
        let playbackRequestID = renewPlaybackRequestLocked()
        stateLock.unlock()
        controlQueue.async {
            self.appliedPlaybackRequestID = playbackRequestID
            // キャンセル後に完了した準備タスクの結果を受け付けない。
            self.loadGeneration += 1
            self.preparationTask?.cancel()
            self.preparationTask = nil
            self.playWhenReady = false
            self.performStop(reset: true)
            self.idleSuspension.cancel()
            self.engine.stop()
            self.reverb.reset()
            self.outputProtection.reset()
            self.releaseLoadedAudio()
            self.loudnessNormalization.load(nil)
        }
    }

    func performEngineReset() {
        idleSuspension.cancel()
        let resumeTime = currentTime
        stateLock.lock()
        let wasPlaying = displayIsPlaying
        stateLock.unlock()
        let volume = playerNode.volume
        let pitch = pitchEffect.pitchCents
        let rate = timePitch.rate

        setDisplayClock(playing: false)
        invalidateScheduledSegment()
        playerNode.stop()
        outputProtection.outputNode.removeTap(onBus: 0)
        engine.stop()

        engine = engineFactory()
        playerNode = AVAudioPlayerNode()
        timePitch = AudioProcessingQuality.makeTimePitch()
        pitchEffect = SMPPitchEffect()
        fadeMixer = AVAudioMixerNode()
        loudnessGain = AVAudioUnitEQ(numberOfBands: 0)
        graphicEQ = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)
        reverb = AVAudioUnitReverb()
        outputProtection = AudioOutputProtection()
        loadedReverbPreset = nil
        buildEngineGraph()

        playerNode.volume = volume
        pitchEffect.pitchCents = pitch
        timePitch.rate = rate
        timePitch.bypass = rate == 1
        applyLoudnessGain(loudnessNormalization.gainForPlayback)

        // ファイルの読み取り状態も含めて作り直す(失敗時は既存のファイルを使い続ける)
        if let url = currentReadableFile?.url, let freshFile = try? AVAudioFile(forReading: url) {
            audioFile = freshFile
        }
        seekFrame = frame(for: resumeTime)
        resetDisplayClock(to: Double(seekFrame) / sampleRate)
        if wasPlaying {
            performPlay()
        }
    }

    // Registration and Audio Unit initialization can wait on CoreAudio.
}

import AVFoundation
import Foundation

nonisolated extension AudioEngineService {
    var pitchEffect: SMPPitchEffect {
        get {
            dispatchPrecondition(condition: .onQueue(controlQueue))
            if let pitchEffectStorage { return pitchEffectStorage }
            let effect = SMPPitchEffect()
            pitchEffectStorage = effect
            return effect
        }
        set {
            dispatchPrecondition(condition: .onQueue(controlQueue))
            pitchEffectStorage = newValue
        }
    }

    // 再生位置・再生状態・各種設定を引き継いで、エンジンと全ノードを作り直す。
    func resetEngine() {
        controlQueue.async {
            self.performEngineReset()
        }
    }

    // シーク連打に備えて要求は最新値だけ保持し、キュー上で順番が来た時点の
    // 最新要求のみを実行する(先行のキュー項目が消費済みなら何もしない)
    func seek(to time: TimeInterval, autoPlay: Bool) {
        let seekID = UUID()
        stateLock.lock()
        let requestID = activeLoadID
        pendingSeek = PendingSeek(time: time, autoPlay: autoPlay, loadID: requestID, seekID: seekID)
        let playbackRequestID = renewPlaybackRequestLocked()
        stateLock.unlock()
        controlQueue.async {
            self.appliedPlaybackRequestID = playbackRequestID
            self.performPendingSeek(for: requestID, seekID: seekID)
        }
    }

    func observeEngineConfiguration() {
        let observedEngine = engine
        configurationObservation = AudioEngineConfigurationObservation(engine: observedEngine) { [weak self] in
            self?.controlQueue.async { [weak self] in
                guard let self, self.engine === observedEngine else { return }
                self.recoverFromConfigurationChange()
            }
        }
    }

    func recoverFromConfigurationChange() {
        guard engine.isRunning == false else { return }
        // User intent is published before its control-queue work. A queued pause,
        // stop, seek or load must win over an older route-change notification.
        let shouldResume = stateLock.withLock {
            displayIsPlaying && appliedPlaybackRequestID == activePlaybackRequestID
        }
        guard shouldResume else { return }
        let resumeTime = currentTime
        idleSuspension.cancel()
        invalidateScheduledSegment()
        playerNode.stop()
        resetPitchProcessors()
        reverb.reset()
        graphicEQ.reset()
        outputProtection.reset()
        seekFrame = frame(for: resumeTime)
        setDisplayClock(playing: false)
        resetDisplayClock(to: Double(seekFrame) / sampleRate)
        performPlay()
    }

    var idleSuspension: AudioEngineIdleSuspension {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        if let idleSuspensionStorage { return idleSuspensionStorage }
        let schedule: AudioEngineIdleSuspension.Schedule?
        if let scheduleIdleSuspension {
            schedule = { [controlQueue] delay, work in
                scheduleIdleSuspension(delay, controlQueue, work)
            }
        } else {
            schedule = nil
        }
        let suspension = AudioEngineIdleSuspension(controlQueue: controlQueue, schedule: schedule)
        idleSuspensionStorage = suspension
        return suspension
    }

    // Inspect on the owner queue, including any operations enqueued before this read.
    var isEngineRunning: Bool {
        get async {
            await withCheckedContinuation { continuation in
                controlQueue.async { continuation.resume(returning: self.engine.isRunning) }
            }
        }
    }

    var pendingPreparationTask: Task<Void, Never>? {
        get async {
            await withCheckedContinuation { continuation in
                controlQueue.async { continuation.resume(returning: self.preparationTask) }
            }
        }
    }

    func finishPreparationWithoutAudio() {
        preparationTask = nil
        playWhenReady = false
        loudnessNormalization.load(nil)
        setCachedDuration(0)
        suspendAfterTail()
    }

    func performPlay() {
        guard let audioFile, let requestID = appliedPlaybackRequestID,
              isActivePlaybackRequest(requestID) else { return }
        idleSuspension.cancel()
        guard seekFrame < audioFile.length else {
            finishPlayback(at: audioFile.length)
            return
        }
        loudnessNormalization.resume()
        do {
            if engine.isRunning == false {
                outputProtection.outputNode.removeTap(onBus: 0)
                try outputProtection.connect(to: engine)
                installTap()
                try engine.start()
            }
            guard continuePlayback(ifCurrent: requestID) else { return }
            if playerNode.isPlaying == false {
                schedule(file: audioFile, from: seekFrame)
                // schedule直後にplayすると、ファイル先読みが数msぶんしか
                // 間に合わず冒頭で音が途切れて「プツッ」というノイズになる
                // (起動直後・デバッガ接続時などディスク読みが遅い時に顕在化)。
                // 0.5秒ぶん先読みを済ませてから再生を開始する
                preparePlayer(playerNode, AVAudioFrameCount(sampleRate / 2))
                guard continuePlayback(ifCurrent: requestID) else { return }
                playerNode.play()
            }
            let didPublish = stateLock.withLock {
                guard activePlaybackRequestID == requestID else { return false }
                displayIsPlaying = true
                return true
            }
            if didPublish == false { _ = continuePlayback(ifCurrent: requestID) }
        } catch {
            guard continuePlayback(ifCurrent: requestID) else { return }
            loudnessNormalization.cancel()
            setDisplayClock(playing: false)
            suspendAfterTail()
            reportError(error, playbackRequestID: requestID)
        }
    }

    // Engine start and player preparation can block. Recheck the request after each
    // one without holding stateLock across AudioUnit operations.
    func continuePlayback(ifCurrent requestID: UUID) -> Bool {
        guard isActivePlaybackRequest(requestID) == false else { return true }
        invalidateScheduledSegment()
        playerNode.stop()
        resetPitchProcessors()
        setDisplayClock(playing: false)
        loudnessNormalization.cancel()
        suspendAfterTail()
        return false
    }

    func performStop(reset: Bool) {
        loudnessNormalization.cancel()
        let stoppedTime = currentTime
        setDisplayClock(playing: false)
        invalidateScheduledSegment()
        stopWithFadeOut()
        seekFrame = reset ? 0 : frame(for: stoppedTime)
        resetDisplayClock(to: Double(seekFrame) / sampleRate)
        suspendAfterTail()
    }

    func suspendAfterTail() {
        guard engine.isRunning else {
            idleSuspension.cancel()
            return
        }
        idleSuspension.request(settings: currentEqualizerSettings) { [weak self] in
            guard let self else { return }
            // A cold decoder may outlive the tail deadline. Keep the engine ready
            // only while that preparation still has a pending playback request.
            if self.preparationTask == nil || self.playWhenReady == false {
                self.engine.pause()
            }
            // Clear remaining delay buffers at the tail deadline, including when
            // the engine stays ready, so the next segment cannot revive the tail.
            self.reverb.reset()
            self.graphicEQ.reset()
            self.outputProtection.reset()
        }
    }

    func finishPlayback(at finalFrame: AVAudioFramePosition) {
        loudnessNormalization.cancel()
        setDisplayClock(playing: false)
        invalidateScheduledSegment()
        playerNode.stop()
        resetPitchProcessors()
        seekFrame = finalFrame
        resetDisplayClock(to: Double(finalFrame) / sampleRate)
        suspendAfterTail()
        notifyFinished()
    }

    // 終端処理が controlQueue に積まれた後、MainActor で曲の切り替え・停止・
    // 一時停止・シーク・再開が呼ばれることがある。終端時点で最後に処理していた
    // 再生操作の ID を MainActor 上で照合し、その後に操作があれば通知しない
    func notifyFinished() {
        guard let playbackRequestID = appliedPlaybackRequestID else { return }
        deliverFinishNotification {
            guard self.isActivePlaybackRequest(playbackRequestID) else { return }
            self.onFinished?()
        }
    }
}

import AVFoundation
import Foundation

private struct PendingSeek {
    let time: TimeInterval
    let autoPlay: Bool
    let loadID: UUID
    let seekID: UUID
}

// AVAudio 系の操作(stop / scheduleSegment など)は内部で下位 QoS スレッドとの
// 同期待ちを伴うため、すべて専用の直列キュー(controlQueue)上で実行し、
// メインスレッドをブロックさせない。UI へ公開する currentTime / duration は
// ロックで守った表示用クロックのキャッシュのみを参照する。
nonisolated final class AudioEngineService: @unchecked Sendable {
    // resetEngine() でインスタンスごと作り直すため var(controlQueue 上でのみ差し替える)
    private var engine: AVAudioEngine
    private var playerNode = AVAudioPlayerNode()
    private var timePitch = AudioProcessingQuality.makeTimePitch()
    private var pitchEffectStorage: SMPPitchEffect?
    private var fadeMixer = AVAudioMixerNode()
    private var loudnessGain = AVAudioUnitEQ(numberOfBands: 0)
    private var graphicEQ = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)
    private var reverb = AVAudioUnitReverb()
    private var outputProtection = AudioOutputProtection()
    private var configurationObservation: AudioEngineConfigurationObservation?
    private let analyzer: SpectrumAnalyzer
    private let openReadableFile: @Sendable (URL) throws -> ExtendedAudioCache.ReadableFile
    private let waitForFadeStep: @Sendable (useconds_t) -> Void
    private let engineFactory: @Sendable () -> AVAudioEngine
    private let preparePlayer: @Sendable (AVAudioPlayerNode, AVAudioFrameCount) -> Void
    typealias IdleSchedule = @Sendable (TimeInterval, DispatchQueue, DispatchWorkItem) -> Void
    private let scheduleIdleSuspension: IdleSchedule?
    private let controlQueue = DispatchQueue(label: "SimpleMediaPlayer.AudioEngineService.control", qos: .userInitiated)

    // controlQueue 上でのみ触る状態
    private var loudnessNormalizationStorage: AudioLoudnessNormalization?
    private var audioFile: AVAudioFile?
    private var currentURL: URL?
    private var currentReadableFile: ExtendedAudioCache.ReadableFile?
    // 最後に処理した再生操作の ID。終端通知をその操作に結び付ける
    private var appliedPlaybackRequestID: UUID?
    private var preparationTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var playWhenReady = false
    private var startFrame: AVAudioFramePosition = 0
    private var seekFrame: AVAudioFramePosition = 0
    private var sampleRate: Double = 44_100
    private var scheduleGeneration = 0
    private var currentEqualizerSettings = EqualizerSettings.flat
    private var loadedReverbPreset: EqualizerReverbPreset?
    private var idleSuspensionStorage: AudioEngineIdleSuspension?

    // メインスレッド・タップコールバックと共有する公開状態(stateLock で保護)
    private let stateLock = NSLock()
    private var displayBaseTime: TimeInterval = 0
    private var displayElapsedTime: TimeInterval = 0
    private var displayLatencyRemaining: TimeInterval = 0
    private var displayIsPlaying = false
    private var displayRate: Double = 1.0
    private var cachedDuration: TimeInterval = 0
    private var pendingSeek: PendingSeek?
    private var activeLoadID = UUID()
    // 再生状態を変える操作を呼ぶたびに更新する。終端通知の有効性判定に使う
    private var activePlaybackRequestID = UUID()

    var onFinished: (@MainActor () -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onFormatLoaded: (@MainActor (_ duration: TimeInterval, _ formatInfo: MediaFormatInfo) -> Void)?

    init(
        analyzer: SpectrumAnalyzer,
        openReadableFile: @escaping @Sendable (URL) throws -> ExtendedAudioCache.ReadableFile = {
            try ExtendedAudioSource.readableFile(for: $0)
        },
        waitForFadeStep: @escaping @Sendable (useconds_t) -> Void = { usleep($0) },
        scheduleIdleSuspension: IdleSchedule? = nil,
        engineFactory: @escaping @Sendable () -> AVAudioEngine = { AVAudioEngine() },
        preparePlayer: @escaping @Sendable (AVAudioPlayerNode, AVAudioFrameCount) -> Void = {
            $0.prepare(withFrameCount: $1)
        }
    ) {
        self.analyzer = analyzer
        self.openReadableFile = openReadableFile
        self.waitForFadeStep = waitForFadeStep
        self.scheduleIdleSuspension = scheduleIdleSuspension
        self.engineFactory = engineFactory
        self.preparePlayer = preparePlayer
        engine = engineFactory()
        controlQueue.async { self.buildEngineGraph() }
    }

    private var loudnessNormalization: AudioLoudnessNormalization {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        if let loudnessNormalizationStorage { return loudnessNormalizationStorage }
        let normalization = AudioLoudnessNormalization(controlQueue: controlQueue) { [weak self] gain in
            self?.applyLoudnessGain(gain)
        }
        loudnessNormalizationStorage = normalization
        return normalization
    }

    // 初回構築も再構築も controlQueue 上。後続の load / play より先に実行する。
    private func buildEngineGraph() {
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

    private func prepareAudio(url: URL, generation: Int, requestID: UUID) {
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

    private func acceptPreparedAudio(
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

    private func releaseLoadedAudio() {
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

    private func performEngineReset() {
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

}

nonisolated extension AudioEngineService {
    // Registration and Audio Unit initialization can wait on CoreAudio.
    private var pitchEffect: SMPPitchEffect {
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

    private func observeEngineConfiguration() {
        let observedEngine = engine
        configurationObservation = AudioEngineConfigurationObservation(engine: observedEngine) { [weak self] in
            self?.controlQueue.async { [weak self] in
                guard let self, self.engine === observedEngine else { return }
                self.recoverFromConfigurationChange()
            }
        }
    }

    private func recoverFromConfigurationChange() {
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

    private var idleSuspension: AudioEngineIdleSuspension {
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

    private func finishPreparationWithoutAudio() {
        preparationTask = nil
        playWhenReady = false
        loudnessNormalization.load(nil)
        setCachedDuration(0)
        suspendAfterTail()
    }

    private func performPlay() {
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
    private func continuePlayback(ifCurrent requestID: UUID) -> Bool {
        guard isActivePlaybackRequest(requestID) == false else { return true }
        invalidateScheduledSegment()
        playerNode.stop()
        resetPitchProcessors()
        setDisplayClock(playing: false)
        loudnessNormalization.cancel()
        suspendAfterTail()
        return false
    }

    private func performStop(reset: Bool) {
        loudnessNormalization.cancel()
        let stoppedTime = currentTime
        setDisplayClock(playing: false)
        invalidateScheduledSegment()
        stopWithFadeOut()
        seekFrame = reset ? 0 : frame(for: stoppedTime)
        resetDisplayClock(to: Double(seekFrame) / sampleRate)
        suspendAfterTail()
    }

    private func suspendAfterTail() {
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

    private func finishPlayback(at finalFrame: AVAudioFramePosition) {
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
    private func notifyFinished() {
        guard let playbackRequestID = appliedPlaybackRequestID else { return }
        Task { @MainActor in
            guard self.isActivePlaybackRequest(playbackRequestID) else { return }
            self.onFinished?()
        }
    }

    // 設定を再生中に切り替えても段差ノイズが出ないよう、補正量を短くランプさせる。
    // controlQueue 上でのみ呼ぶこと。
    private func applyLoudnessGain(_ decibels: Float) {
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

    private func configureGraphicEqualizerBands() {
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

    private func applyEqualizer(_ settings: EqualizerSettings) {
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
    private func stopWithFadeOut() {
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

    private func resetPitchProcessors() {
        timePitch.reset()
        pitchEffect.reset()
    }

    private var playbackProcessingLatency: TimeInterval {
        max(0, pitchEffect.latency + outputProtection.latency)
    }

    private func performPendingSeek(for requestID: UUID, seekID: UUID? = nil) {
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

    private func schedule(file: AVAudioFile, from frame: AVAudioFramePosition) {
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

    private func invalidateScheduledSegment() {
        scheduleGeneration += 1
    }

    private func frame(for time: TimeInterval) -> AVAudioFramePosition {
        AVAudioFramePosition(max(0, min(duration, time)) * sampleRate)
    }

    // 実ファイルサイズ ÷ 再生時間からの概算(可変ビットレートやロスレスでも実測値になる)
    private static func estimatedBitrateKbps(url: URL, duration: TimeInterval) -> Int {
        guard duration > 0,
              let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              fileSize > 0
        else {
            return 0
        }
        return Int((Double(fileSize) * 8 / duration / 1000).rounded())
    }

    private func reportError(_ error: Error, for requestID: UUID? = nil, playbackRequestID: UUID? = nil) {
        let message = error.localizedDescription
        Task { @MainActor in
            if let requestID, self.isActiveLoad(requestID) == false { return }
            if let playbackRequestID, self.isActivePlaybackRequest(playbackRequestID) == false { return }
            self.onError?(message)
        }
    }

    private func isActiveLoad(_ requestID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeLoadID == requestID
    }

    private func isActivePlaybackRequest(_ requestID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activePlaybackRequestID == requestID
    }

    // stateLock を保持した状態で呼ぶこと
    private func renewPlaybackRequestLocked() -> UUID {
        let requestID = UUID()
        activePlaybackRequestID = requestID
        return requestID
    }

    private func installTap() {
        outputProtection.outputNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let clock = self.advanceDisplayClock(byFrames: buffer.frameLength, sampleRate: buffer.format.sampleRate)
            self.analyzer.analyze(buffer, currentTime: clock.time, isPlaying: clock.isPlaying)
        }
    }

    private func setCachedDuration(_ value: TimeInterval) {
        stateLock.lock()
        cachedDuration = value
        stateLock.unlock()
    }

    private func setDisplayClock(playing: Bool) {
        stateLock.lock()
        displayIsPlaying = playing
        stateLock.unlock()
    }

    private func resetDisplayClock(to time: TimeInterval, latency: TimeInterval = 0) {
        stateLock.lock()
        displayBaseTime = time
        displayElapsedTime = 0
        displayLatencyRemaining = latency
        stateLock.unlock()
    }

    private func advanceDisplayClock(
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

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
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private var loudnessGain = AVAudioUnitEQ(numberOfBands: 0)
    private var graphicEQ = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)
    private var reverb = AVAudioUnitReverb()
    private let analyzer: SpectrumAnalyzer
    private let controlQueue = DispatchQueue(label: "SimpleMediaPlayer.AudioEngineService.control", qos: .userInitiated)

    // controlQueue 上でのみ触る状態
    private var loudnessNormalizationStorage: AudioLoudnessNormalization?
    private var audioFile: AVAudioFile?
    private var currentURL: URL?
    private var currentReadableFile: ExtendedAudioCache.ReadableFile?
    // audioFile を読み込んだ load の ID。終端通知を発行元の曲に結び付ける
    private var loadedRequestID: UUID?
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
    private var displayIsPlaying = false
    private var displayRate: Double = 1.0
    private var cachedDuration: TimeInterval = 0
    private var pendingSeek: PendingSeek?
    private var activeLoadID = UUID()

    var onFinished: (@MainActor () -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onFormatLoaded: (@MainActor (_ duration: TimeInterval, _ formatInfo: MediaFormatInfo) -> Void)?

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        buildEngineGraph()
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

    private var idleSuspension: AudioEngineIdleSuspension {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        if let idleSuspensionStorage { return idleSuspensionStorage }
        let suspension = AudioEngineIdleSuspension(controlQueue: controlQueue)
        idleSuspensionStorage = suspension
        return suspension
    }

    // init と performEngineReset からのみ呼ぶ(reset 時は controlQueue 上)
    private func buildEngineGraph() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.attach(loudnessGain)
        engine.attach(graphicEQ)
        engine.attach(reverb)
        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: loudnessGain, format: nil)
        engine.connect(loudnessGain, to: graphicEQ, format: nil)
        engine.connect(graphicEQ, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        loudnessGain.bypass = true
        configureGraphicEqualizerBands()
        applyEqualizer(currentEqualizerSettings)
        installTap()
    }

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
            self.timePitch.pitch = clamped
        }
    }

    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.25, min(4.0, rate))
        controlQueue.async {
            self.timePitch.rate = clamped
        }
        stateLock.lock()
        displayRate = Double(clamped)
        stateLock.unlock()
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
        stateLock.unlock()
        controlQueue.async {
            self.preparationTask?.cancel()
            self.loadGeneration += 1
            let generation = self.loadGeneration
            self.performStop(reset: true)
            self.releaseLoadedAudio()
            self.currentURL = url
            self.playWhenReady = false
            self.setCachedDuration(0)
            self.preparationTask = Task.detached(priority: .userInitiated) {
                self.prepareAudio(url: url, generation: generation, requestID: requestID)
            }
        }
    }

    private func prepareAudio(url: URL, generation: Int, requestID: UUID) {
        do {
            let readableFile = try ExtendedAudioSource.readableFile(for: url)
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
            return
        } catch {
            controlQueue.async {
                guard generation == self.loadGeneration, self.isActiveLoad(requestID) else { return }
                self.preparationTask = nil
                self.loudnessNormalization.load(nil)
                self.setCachedDuration(0)
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
        loadedRequestID = requestID
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

    func play() {
        controlQueue.async {
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
        stateLock.unlock()
        controlQueue.async {
            self.playWhenReady = false
            self.loudnessNormalization.cancel()
            self.seekFrame = self.frame(for: self.preciseCurrentTime())
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
        stateLock.unlock()
        controlQueue.async {
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
        stateLock.unlock()
        controlQueue.async {
            // キャンセル後に完了した準備タスクの結果を受け付けない。
            self.loadGeneration += 1
            self.preparationTask?.cancel()
            self.preparationTask = nil
            self.playWhenReady = false
            self.performStop(reset: true)
            self.idleSuspension.cancel()
            self.engine.stop()
            self.reverb.reset()
            self.releaseLoadedAudio()
            self.loudnessNormalization.load(nil)
        }
    }

    // 再生速度の変更を繰り返すと特定の周波数帯が消えることがある(原因未特定、
    // AVAudioUnitTimePitch 内部状態の破損を疑っている)ため、切り分け用に
    // エンジンと全ノードをインスタンスごと作り直す完全リセットを提供する。
    // 再生位置・再生状態・音量・ピッチ・速度は引き継ぐ
    func resetEngine() {
        controlQueue.async {
            self.performEngineReset()
        }
    }

    private func performEngineReset() {
        idleSuspension.cancel()
        let resumeTime = preciseCurrentTime()
        stateLock.lock()
        let wasPlaying = displayIsPlaying
        stateLock.unlock()
        let volume = playerNode.volume
        let pitch = timePitch.pitch
        let rate = timePitch.rate

        setDisplayClock(playing: false)
        invalidateScheduledSegment()
        playerNode.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()

        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        timePitch = AVAudioUnitTimePitch()
        loudnessGain = AVAudioUnitEQ(numberOfBands: 0)
        graphicEQ = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)
        reverb = AVAudioUnitReverb()
        loadedReverbPreset = nil
        buildEngineGraph()

        playerNode.volume = volume
        timePitch.pitch = pitch
        timePitch.rate = rate
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

    // シーク連打に備えて要求は最新値だけ保持し、キュー上で順番が来た時点の
    // 最新要求のみを実行する(先行のキュー項目が消費済みなら何もしない)
    func seek(to time: TimeInterval, autoPlay: Bool) {
        let seekID = UUID()
        stateLock.lock()
        let requestID = activeLoadID
        pendingSeek = PendingSeek(time: time, autoPlay: autoPlay, loadID: requestID, seekID: seekID)
        stateLock.unlock()
        controlQueue.async {
            self.performPendingSeek(for: requestID, seekID: seekID)
        }
    }

    private func performPlay() {
        idleSuspension.cancel()
        guard let audioFile else { return }
        guard seekFrame < audioFile.length else {
            finishPlayback(at: audioFile.length)
            return
        }
        loudnessNormalization.resume()
        do {
            if engine.isRunning == false {
                try engine.start()
            }
            if playerNode.isPlaying == false {
                schedule(file: audioFile, from: seekFrame)
                // schedule直後にplayすると、ファイル先読みが数msぶんしか
                // 間に合わず冒頭で音が途切れて「プツッ」というノイズになる
                // (起動直後・デバッガ接続時などディスク読みが遅い時に顕在化)。
                // 0.5秒ぶん先読みを済ませてから再生を開始する
                playerNode.prepare(withFrameCount: AVAudioFrameCount(sampleRate / 2))
                playerNode.play()
            }
            setDisplayClock(playing: true)
        } catch {
            loudnessNormalization.cancel()
            setDisplayClock(playing: false)
            suspendAfterTail()
            reportError(error)
        }
    }

    private func performStop(reset: Bool) {
        loudnessNormalization.cancel()
        let stoppedTime = preciseCurrentTime()
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
            self.engine.pause()
            // A paused audio unit retains its delay buffers. Clear any remaining
            // tail so it cannot sound again when the next segment starts.
            self.reverb.reset()
            self.graphicEQ.reset()
        }
    }

}

nonisolated extension AudioEngineService {
    private func releaseLoadedAudio() {
        audioFile = nil
        loadedRequestID = nil
        currentReadableFile?.release()
        currentReadableFile = nil
        currentURL = nil
    }

    private func finishPlayback(at finalFrame: AVAudioFramePosition) {
        loudnessNormalization.cancel()
        setDisplayClock(playing: false)
        invalidateScheduledSegment()
        playerNode.stop()
        timePitch.reset()
        seekFrame = finalFrame
        resetDisplayClock(to: Double(finalFrame) / sampleRate)
        suspendAfterTail()
        notifyFinished()
    }

    // 終端処理が controlQueue に積まれた後、MainActor で次の曲の load が
    // 呼ばれることがある。通知時点の activeLoadID ではなく、終端に達した
    // 曲の load ID を MainActor 上で照合し、切り替え後の曲を基準に
    // onFinished が走らないようにする
    private func notifyFinished() {
        guard let requestID = loadedRequestID else { return }
        Task { @MainActor in
            guard self.isActiveLoad(requestID) else { return }
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

    // 再生中に playerNode.stop() を直接呼ぶと波形が振幅の途中でぶつ切りになり、
    // 切る瞬間の振幅が大きいと「プツッ」というノイズになる(曲の切り替え・停止・
    // シーク時)。ミキサーへの入力音量を短時間で0まで落としてから止め、音量を
    // 元に戻す。controlQueue 上でのみ呼ぶこと
    private func stopWithFadeOut() {
        guard playerNode.isPlaying else {
            playerNode.stop()
            timePitch.reset()
            return
        }
        let original = playerNode.volume
        if original > 0 {
            let steps = 10
            for step in 1...steps {
                playerNode.volume = original * Float(steps - step) / Float(steps)
                usleep(6000)
            }
            // 最後の音量変更(→0)のミキサー内部平滑が完了するのを待ってから止める。
            // 待ちが足りないと小さな段差が残って微かにプツッと鳴る
            usleep(15000)
        }
        playerNode.stop()
        timePitch.reset()
        playerNode.volume = original
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
        guard let audioFile else { return }
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
        resetDisplayClock(to: Double(frame) / sampleRate)
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
                guard generation == self.scheduleGeneration else { return }
                self.finishPlayback(at: file.length)
            }
        }
    }

    private func invalidateScheduledSegment() {
        scheduleGeneration += 1
    }

    // playerNode 内部のロックを取るため controlQueue 上でのみ呼ぶこと
    private func preciseCurrentTime() -> TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return Double(seekFrame) / sampleRate
        }
        return Double(seekFrame + AVAudioFramePosition(playerTime.sampleTime)) / sampleRate
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

    private func reportError(_ error: Error, for requestID: UUID? = nil) {
        let message = error.localizedDescription
        Task { @MainActor in
            if let requestID, self.isActiveLoad(requestID) == false { return }
            self.onError?(message)
        }
    }

    private func isActiveLoad(_ requestID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeLoadID == requestID
    }

    private func installTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
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

    private func resetDisplayClock(to time: TimeInterval) {
        stateLock.lock()
        displayBaseTime = time
        displayElapsedTime = 0
        stateLock.unlock()
    }

    private func advanceDisplayClock(
        byFrames frames: AVAudioFrameCount,
        sampleRate: Double
    ) -> (time: TimeInterval, isPlaying: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if displayIsPlaying, sampleRate > 0 {
            displayElapsedTime += Double(frames) / sampleRate * displayRate
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

import AVFoundation
import Foundation
import Observation

@MainActor
protocol MediaURLResolving: AnyObject {
    func resolvedURL(for item: MediaItem) -> URL?
}

@MainActor
protocol AudioPlaybackControlling: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var onFinished: (@MainActor () -> Void)? { get set }
    var onError: (@MainActor (String) -> Void)? { get set }
    var onFormatLoaded: (@MainActor (_ duration: TimeInterval, _ formatInfo: MediaFormatInfo) -> Void)? { get set }

    func setVolume(_ volume: Float)
    func setPitchCents(_ cents: Float)
    func setPlaybackRate(_ rate: Float)
    func setVolumeNormalizationEnabled(_ enabled: Bool)
    func setEqualizer(_ settings: EqualizerSettings)
    func load(url: URL)
    func play()
    func pause()
    func stop(reset: Bool)
    func suspend()
    func seek(to time: TimeInterval, autoPlay: Bool)
    func resetEngine()
}

@MainActor
protocol VideoPlaybackControlling: AnyObject {
    var player: AVPlayer { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var onFinished: (() -> Void)? { get set }
    var onFormatLoaded: (@MainActor (MediaFormatInfo) -> Void)? { get set }

    func load(url: URL) async
    func play()
    func pause()
    func setVolume(_ volume: Float)
    func setEqualizer(_ settings: EqualizerSettings)
    func stop()
    func close()
    func seek(to time: TimeInterval)
}

@MainActor
@Observable
final class PlayerViewModel {
    var currentItem: MediaItem?
    var queue: [MediaItem] = []
    private(set) var isPaused = false
    var isPlaying = false {
        didSet {
            if isPlaying { isPaused = false }
            guard isPlaying != oldValue else { return }
            audioFrame.isPlaying = isPlaying
            analyzer.setPlaybackActive(isPlaying, currentTime: currentTime)
            updateClock()
        }
    }
    private(set) var playbackGeneration: UInt64 = 0
    /// Advances on every transport action, including pause and resume, which keep `playbackGeneration`.
    /// A deferred playback request compares it so a pause/resume pair in between is not mistaken for
    /// an unchanged state.
    private(set) var transportGeneration: UInt64 = 0
    @ObservationIgnored private let playbackClock = PlaybackClock()
    var currentTime: TimeInterval {
        get { playbackClock.time }
        set { playbackClock.update(to: newValue) }
    }
    var elapsedSeconds: Int { playbackClock.elapsedSeconds }
    var canPlayPrevious: Bool {
        canSkipToPrevious || (currentItem != nil && playbackClock.canRestart)
    }
    var duration: TimeInterval = 0
    var audioFrame = AudioFrameData.silent()
    var isVideoMode = false
    var showVideoArea = false
    var errorMessage: String?
    var volume = 0.75
    var isMuted = false
    var formatInfo = MediaFormatInfo.empty
    var spectrumFrameRate = 0
    var pitchSemitones = 0
    var playbackRate = 1.0
    let musicAnalysis: MusicAnalysisController
    var volumeNormalizationEnabled: Bool
    var equalizer: EqualizerSettings
    var userEqualizerPresets: [UserEqualizerPreset]

    static let pitchSemitoneRange = -6...6
    static let playbackRateRange = 0.5...2.0
    static let playbackRateStep = 0.05

    var canResume: Bool {
        currentItem != nil && isPlaying == false
    }

    var hasPitchOrRateAdjustment: Bool {
        pitchSemitones != 0 || abs(playbackRate - 1.0) > 0.001
    }

    var activeEqualizerPresetName: String {
        guard equalizer.isEnabled else { return L10n.string("Off") }
        if let preset = BuiltInEqualizerPreset.allCases.first(where: { $0.settings == equalizer }) {
            return preset.name
        }
        if let preset = userEqualizerPresets.first(where: { $0.settings == equalizer }) {
            return preset.name
        }
        return L10n.string("Custom")
    }

    var canPause: Bool {
        currentItem != nil && isPlaying
    }

    var canStop: Bool {
        currentItem != nil
    }

    var canSkipToNext: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            return false
        }
        return queue.indices.contains(queue.index(after: index))
    }

    var canSkipToPrevious: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            return false
        }
        return index > queue.startIndex
    }

    @ObservationIgnored private let libraryService: any MediaURLResolving
    @ObservationIgnored private let analyzer: SpectrumAnalyzer
    @ObservationIgnored private let audioEngine: any AudioPlaybackControlling
    @ObservationIgnored let videoService: any VideoPlaybackControlling
    @ObservationIgnored private let equalizerDefaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let clockEnabled: Bool
    /// Alive while a transient item is current or queued; see `TransientPlaybackSession`.
    @ObservationIgnored private(set) var transientSession: TransientPlaybackSession?
    private var lastAudibleVolume = 0.75
    @ObservationIgnored private var spectrumFrameRateCounter = SpectrumFrameRateCounter()

    convenience init(libraryService: LibraryService) {
        let analyzer = SpectrumAnalyzer()
        self.init(
            libraryService: libraryService,
            analyzer: analyzer,
            audioEngine: AudioEngineService(analyzer: analyzer),
            videoService: VideoPlayerService(analyzer: analyzer),
            volumeNormalizationEnabled: UserDefaults.standard.object(
                forKey: AppSettingsKey.volumeNormalizationEnabled
            ) as? Bool ?? AppSettingsDefault.volumeNormalizationEnabled,
            equalizer: EqualizerSettings.load()
        )
    }

    init(
        libraryService: any MediaURLResolving,
        analyzer: SpectrumAnalyzer = SpectrumAnalyzer(),
        audioEngine: any AudioPlaybackControlling,
        videoService: any VideoPlaybackControlling,
        startsClock: Bool = true,
        volumeNormalizationEnabled: Bool = AppSettingsDefault.volumeNormalizationEnabled,
        equalizer: EqualizerSettings = .flat,
        equalizerDefaults: UserDefaults = .standard,
        musicAnalysis: MusicAnalysisController = MusicAnalysisController()
    ) {
        self.libraryService = libraryService
        self.analyzer = analyzer
        self.audioEngine = audioEngine
        self.videoService = videoService
        self.volumeNormalizationEnabled = volumeNormalizationEnabled
        self.equalizer = equalizer
        self.equalizerDefaults = equalizerDefaults
        self.musicAnalysis = musicAnalysis
        self.clockEnabled = startsClock
        self.userEqualizerPresets = UserEqualizerPreset.load(from: equalizerDefaults)
        analyzer.onFrame = { [weak self] frame in
            self?.acceptAudioFrame(frame)
        }
        audioEngine.onFinished = { [weak self] in
            // 停止・一時停止の直前に終端へ達した曲の通知では次の曲へ進まない
            guard let self, self.isPlaying, !self.isVideoMode else { return }
            self.next()
        }
        videoService.onFinished = { [weak self] in
            self?.next()
        }
        videoService.onFormatLoaded = { [weak self] formatInfo in
            self?.formatInfo = formatInfo
        }
        audioEngine.onError = { [weak self] message in
            guard let self, !self.isVideoMode else { return }
            self.playbackGeneration &+= 1
            self.errorMessage = message
            self.isPaused = false
            self.isPlaying = false
            self.formatInfo = .empty
            self.resetSpectrumFrameRate()
        }
        audioEngine.onFormatLoaded = { [weak self] duration, formatInfo in
            self?.duration = duration
            self?.formatInfo = formatInfo
        }
        configureAudioSession()
        audioEngine.setVolumeNormalizationEnabled(volumeNormalizationEnabled)
        audioEngine.setEqualizer(equalizer)
        videoService.setEqualizer(equalizer)
        applyVolume()
    }
}

extension PlayerViewModel {
    func setVisualizerBandCount(_ count: Int?) {
        analyzer.setBandCount(count)
    }

    func setVisualizerResponseMode(_ mode: VisualizerResponseMode) {
        analyzer.setResponseMode(mode)
    }

    func setVolumeNormalizationEnabled(_ enabled: Bool) {
        volumeNormalizationEnabled = enabled
        audioEngine.setVolumeNormalizationEnabled(enabled)
    }

    func setEqualizerEnabled(_ enabled: Bool) {
        updateEqualizer { settings in
            settings.isEnabled = enabled
        }
    }

    func setEqualizerBandGain(index: Int, decibels: Float) {
        guard equalizer.bandGains.indices.contains(index) else { return }
        updateEqualizer { settings in
            settings.bandGains[index] = EqualizerSettings.clampedGain(decibels)
        }
    }

    func setEqualizerPreamp(decibels: Float) {
        updateEqualizer { settings in
            settings.preampDecibels = EqualizerSettings.clampedGain(decibels)
        }
    }

    func setEqualizerReverbPreset(_ preset: EqualizerReverbPreset) {
        updateEqualizer { settings in
            settings.reverbPreset = preset
        }
    }

    func setEqualizerReverbWetDryMix(_ mix: Float) {
        updateEqualizer { settings in
            settings.reverbWetDryMix = EqualizerSettings.clampedReverbWetDryMix(mix)
        }
    }

    func applyEqualizerPreset(_ preset: BuiltInEqualizerPreset) {
        replaceEqualizer(with: preset.settings)
    }

    func applyUserEqualizerPreset(id: UUID) {
        guard let preset = userEqualizerPresets.first(where: { $0.id == id }) else { return }
        var settings = preset.settings
        settings.isEnabled = true
        replaceEqualizer(with: settings)
    }

    func saveCurrentEqualizerPreset(named name: String) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else { return }
        var settings = equalizer
        settings.isEnabled = true
        if let index = userEqualizerPresets.firstIndex(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            userEqualizerPresets[index].name = normalizedName
            userEqualizerPresets[index].settings = settings
        } else {
            userEqualizerPresets.append(UserEqualizerPreset(name: normalizedName, settings: settings))
        }
        UserEqualizerPreset.save(userEqualizerPresets, to: equalizerDefaults)
    }

    func deleteUserEqualizerPreset(id: UUID) {
        userEqualizerPresets.removeAll { $0.id == id }
        UserEqualizerPreset.save(userEqualizerPresets, to: equalizerDefaults)
    }

    func flattenEqualizer() {
        updateEqualizer { settings in
            settings.preampDecibels = 0
            settings.bandGains = Array(repeating: 0, count: EqualizerSettings.bandCount)
            settings.reverbPreset = .mediumRoom
            settings.reverbWetDryMix = 0
        }
    }
}

extension PlayerViewModel {
    /// Plays media that is not in the library. The previous transient session ends after the switch,
    /// so its files are removed only once nothing refers to them.
    func play(transientSession session: TransientPlaybackSession) {
        guard let first = session.items.first else { return }
        let previous = transientSession
        // Taken before `play(item:in:)` starts the new item's analysis, which must not be the task waited on.
        let pending = musicAnalysis.reset()
        transientSession = session
        play(item: first, in: session.items)
        if let previous, previous !== session { endTransientSession(previous, after: pending) }
    }

    func isTransientItem(_ item: MediaItem) -> Bool {
        transientSession?.contains(item.id) == true
    }

    var isPlayingTransientItem: Bool {
        currentItem.map(isTransientItem) == true
    }

    func play(item: MediaItem, in queue: [MediaItem]) {
        playbackGeneration &+= 1
        transportGeneration &+= 1
        releaseTransientSession(unlessContaining: item)
        guard let url = libraryService.resolvedURL(for: item) else {
            clearCurrentItem()
            errorMessage = L10n.format("Could not open file: %@", item.title)
            return
        }
        musicAnalysis.reset()
        isPaused = false
        self.queue = queue
        currentItem = item
        isVideoMode = item.isVideo
        showVideoArea = item.isVideo
        currentTime = 0
        duration = item.duration
        formatInfo = .empty
        resetSpectrumFrameRate()

        isPlaying = false

        if !item.isVideo {
            musicAnalysis.load(url: url)
        }

        if item.isVideo {
            audioEngine.suspend()
            let generation = playbackGeneration
            Task {
                await videoService.load(url: url)
                guard playbackGeneration == generation, currentItem?.id == item.id, isVideoMode else { return }
                duration = videoService.duration > 0 ? videoService.duration : item.duration
                videoService.play()
                isPlaying = true
            }
        } else {
            videoService.close()
            audioEngine.load(url: url)
            audioEngine.play()
            isPlaying = true
            isVideoMode = false
            showVideoArea = false
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard currentItem != nil, isPlaying == false else { return }
        transportGeneration &+= 1
        resetSpectrumFrameRate()
        if isVideoMode {
            videoService.play()
        } else {
            audioEngine.play()
        }
        isPlaying = true
    }

    func pause() {
        guard currentItem != nil, isPlaying else { return }
        transportGeneration &+= 1
        if isVideoMode {
            videoService.pause()
        } else {
            audioEngine.pause()
        }
        isPaused = true
        isPlaying = false
        resetSpectrumFrameRate()
    }

    func stop() {
        playbackGeneration &+= 1
        transportGeneration &+= 1
        isPaused = false
        if isVideoMode {
            closeVideoSession()
        } else {
            audioEngine.stop(reset: true)
            currentTime = 0
            isPlaying = false
            analyzer.setPlaybackActive(false, currentTime: 0)
            resetSpectrumFrameRate()
        }
    }

    func clearCurrentItem() {
        // Released before the analysis reset below so the session can wait for the analysis it cancels.
        releaseTransientSession(unlessContaining: nil)
        musicAnalysis.reset()
        if isVideoMode == false { audioEngine.suspend() }
        stop()
        currentItem = nil
        queue = []
        duration = 0
        formatInfo = .empty
        isVideoMode = false
        showVideoArea = false
    }

    private func releaseTransientSession(unlessContaining item: MediaItem?) {
        guard let session = transientSession else { return }
        if let item, session.contains(item.id) { return }
        transientSession = nil
        endTransientSession(session, after: musicAnalysis.reset())
    }

    /// The analysis task owns the cache write for the session's files, so the files and cache entries are
    /// removed only after that task has finished; otherwise a late write could recreate an entry.
    private func endTransientSession(_ session: TransientPlaybackSession, after pending: Task<Void, Never>?) {
        Task { @MainActor in
            await pending?.value
            session.end()
        }
    }

    func setVolume(_ value: Double) {
        let clamped = max(0, min(1, value))
        volume = clamped
        if clamped > 0 {
            lastAudibleVolume = clamped
            isMuted = false
        }
        applyVolume()
    }

    func toggleMuted() {
        if isMuted {
            isMuted = false
            if volume == 0 {
                volume = lastAudibleVolume
            }
        } else {
            if volume > 0 {
                lastAudibleVolume = volume
            }
            isMuted = true
        }
        applyVolume()
    }

    func setPitchSemitones(_ value: Int) {
        let clamped = max(Self.pitchSemitoneRange.lowerBound, min(Self.pitchSemitoneRange.upperBound, value))
        pitchSemitones = clamped
        audioEngine.setPitchCents(Float(clamped * 100))
    }

    func setPlaybackRate(_ value: Double) {
        let clamped = max(Self.playbackRateRange.lowerBound, min(Self.playbackRateRange.upperBound, value))
        let quantized = (clamped / Self.playbackRateStep).rounded() * Self.playbackRateStep
        playbackRate = quantized
        audioEngine.setPlaybackRate(Float(quantized))
    }

    func resetPitchAndRate() {
        setPitchSemitones(0)
        setPlaybackRate(1.0)
    }

    // 再生速度変更に起因する周波数欠落バグの切り分け用。エンジンを丸ごと
    // 作り直すが、再生位置・再生状態・各種設定はエンジン側が引き継ぐので
    // ViewModel の公開状態はそのままでよい
    func resetAudioEngine() {
        if !isVideoMode { playbackGeneration &+= 1 }
        audioEngine.resetEngine()
    }

    func next() {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            stop()
            return
        }
        let nextIndex = queue.index(after: index)
        guard queue.indices.contains(nextIndex) else {
            stop()
            return
        }
        play(item: queue[nextIndex], in: queue)
    }

    func previous() {
        if currentTime >= 3 {
            seek(to: 0)
            return
        }
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            stop()
            return
        }
        let previousIndex = queue.index(before: index)
        guard queue.indices.contains(previousIndex) else {
            seek(to: 0)
            return
        }
        play(item: queue[previousIndex], in: queue)
    }
}

extension PlayerViewModel {
    func seek(to time: TimeInterval) {
        let target = max(0, min(duration, time))
        currentTime = target
        if isVideoMode {
            videoService.seek(to: target)
        } else {
            audioEngine.seek(to: target, autoPlay: isPlaying)
        }
        // Invalidate chunks scheduled for the position before this seek.
        analyzer.setPlaybackActive(isPlaying, currentTime: target)
    }

    private func updateClock() {
        timer?.invalidate()
        timer = nil
        guard clockEnabled else { return }
        // .common モードで登録しないと、マウストラッキング中（ボタン長押しなど）に
        // RunLoop が .eventTracking モードになりタイマーが発火しない
        // After the engine's asynchronous pause, synchronize the clock once, then rest.
        let timer = Timer(timeInterval: isPlaying ? 1.0 / 30 : 0.5, repeats: isPlaying) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.synchronizePlaybackClock()
            }
        }
        timer.tolerance = 0.003
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func synchronizePlaybackClock() {
        guard isPlaying || currentItem != nil else { return }
        if isVideoMode {
            currentTime = videoService.currentTime
            if duration <= 0, videoService.duration > 0 { duration = videoService.duration }
        } else {
            currentTime = audioEngine.currentTime
            if duration <= 0, audioEngine.duration > 0 { duration = audioEngine.duration }
        }
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    private func applyVolume() {
        let effectiveVolume = isMuted ? Float(0) : Float(volume)
        audioEngine.setVolume(effectiveVolume)
        videoService.setVolume(effectiveVolume)
    }

    private func updateEqualizer(_ update: (inout EqualizerSettings) -> Void) {
        var settings = equalizer
        update(&settings)
        replaceEqualizer(with: settings)
    }

    private func replaceEqualizer(with settings: EqualizerSettings) {
        equalizer = settings
        audioEngine.setEqualizer(settings)
        videoService.setEqualizer(settings)
        settings.save(to: equalizerDefaults)
    }

    private func acceptAudioFrame(_ frame: AudioFrameData) {
        audioFrame = frame
        guard frame.isPlaying else {
            resetSpectrumFrameRate()
            return
        }
        if let frameRate = spectrumFrameRateCounter.recordFrame(at: ProcessInfo.processInfo.systemUptime) {
            spectrumFrameRate = frameRate
        }
    }

    private func resetSpectrumFrameRate() {
        spectrumFrameRate = 0
        spectrumFrameRateCounter.reset()
    }

    private func closeVideoSession() {
        playbackGeneration &+= 1
        musicAnalysis.reset()
        videoService.close()
        currentItem = nil
        queue = []
        currentTime = 0
        duration = 0
        isPaused = false
        isPlaying = false
        isVideoMode = false
        showVideoArea = false
        analyzer.setPlaybackActive(false, currentTime: 0)
        resetSpectrumFrameRate()
    }
}

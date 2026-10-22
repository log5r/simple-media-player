import AVFoundation
import Foundation
import Observation

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
            updateVisualizerIdle()
            analyzer.setPlaybackActive(isPlaying, currentTime: currentTime)
            updateClock()
        }
    }
    private(set) var playbackGeneration: UInt64 = 0
    /// Advances on every transport action, including pause and resume, which keep `playbackGeneration`.
    /// A deferred playback request compares it so a pause/resume pair in between is not mistaken for
    /// an unchanged state.
    private(set) var transportGeneration: UInt64 = 0
    @ObservationIgnored private(set) var deferredPlaybackRequestID: UUID?
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
    /// True while nothing plays and the last frame is silent. It is assigned only when it changes, so a view
    /// that pauses its timeline with it is not invalidated by every analysis frame.
    var isVisualizerIdle = true
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

    @ObservationIgnored let audioSession: PlaybackAudioSession
    var isPreparingPlayback = false
    @ObservationIgnored var pendingPlaybackStart: Task<Void, Never>?
    @ObservationIgnored var pendingVideoLoad: Task<Void, Never>?

    @ObservationIgnored private let libraryService: any MediaURLResolving
    @ObservationIgnored let analyzer: SpectrumAnalyzer
    @ObservationIgnored let audioEngine: any AudioPlaybackControlling
    @ObservationIgnored let videoService: any VideoPlaybackControlling
    @ObservationIgnored let equalizerDefaults: UserDefaults
    @ObservationIgnored var timer: Timer?
    /// The repeating interval of the playback clock, or nil while it rests or is disabled.
    @ObservationIgnored var playbackClockInterval: TimeInterval?
    /// Views on screen that draw `audioFrame`. Analysis stops while there are none or the app is in the background.
    @ObservationIgnored var visualizationConsumers: Set<UUID> = []
    @ObservationIgnored var isInBackground = false
    @ObservationIgnored var isVisualizationSuspended = false
    @ObservationIgnored let clockEnabled: Bool
    /// Alive while a transient item is current or queued; see `TransientPlaybackSession`.
    @ObservationIgnored private(set) var transientSession: TransientPlaybackSession?
    var lastAudibleVolume = 0.75
    @ObservationIgnored var spectrumFrameRateCounter = SpectrumFrameRateCounter()

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
            equalizer: EqualizerSettings.load(),
            audioSession: .system()
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
        musicAnalysis: MusicAnalysisController = MusicAnalysisController(),
        audioSession: PlaybackAudioSession = PlaybackAudioSession()
    ) {
        self.libraryService = libraryService
        self.analyzer = analyzer
        self.audioEngine = audioEngine
        self.videoService = videoService
        self.volumeNormalizationEnabled = volumeNormalizationEnabled
        self.equalizer = equalizer
        self.equalizerDefaults = equalizerDefaults
        self.musicAnalysis = musicAnalysis
        self.audioSession = audioSession
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
            self.cancelPendingPlaybackStart()
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
        updateVisualizationSuspension()
        audioEngine.setVolumeNormalizationEnabled(volumeNormalizationEnabled)
        audioEngine.setEqualizer(equalizer)
        videoService.setEqualizer(equalizer)
        applyVolume()
    }
}

extension PlayerViewModel {
    /// Starts a playback request whose result arrives later. Beginning another one, selecting another
    /// track, or clearing the player supersedes it, so only the latest selection, across all scenes,
    /// can still apply its result.
    func beginDeferredPlaybackRequest() -> DeferredPlaybackRequest {
        let request = DeferredPlaybackRequest(id: UUID(), transportGeneration: transportGeneration)
        deferredPlaybackRequestID = request.id
        return request
    }

    /// True only for the latest deferred request, and only if no transport action happened since it began.
    func canApply(_ request: DeferredPlaybackRequest) -> Bool {
        deferredPlaybackRequestID == request.id && transportGeneration == request.transportGeneration
    }

    /// True while no newer deferred request began, no track was selected, and the player was not cleared.
    /// Unlike `canApply`, pause, resume, and stop do not affect it, so a failure for the song the user
    /// last chose can still be reported.
    func isLatestDeferredRequest(_ request: DeferredPlaybackRequest) -> Bool {
        deferredPlaybackRequestID == request.id
    }

    /// Plays media that is not in the library. The previous transient session ends after the switch,
    /// so its files are removed only once nothing refers to them.
    /// Consumes the pending deferred request through `play(item:in:)`, so its result cannot apply twice.
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
        cancelPendingPlaybackStart()
        pendingVideoLoad = nil
        playbackGeneration &+= 1
        transportGeneration &+= 1
        // Selecting a track supersedes a pending deferred request, including its failure report.
        deferredPlaybackRequestID = nil
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
            let videoService = videoService
            pendingVideoLoad = Task { [weak self] in
                await videoService.load(url: url)
                guard let self, playbackGeneration == generation,
                      currentItem?.id == item.id, isVideoMode else { return }
                duration = videoService.duration > 0 ? videoService.duration : item.duration
                pendingVideoLoad = nil
            }
        } else {
            videoService.close()
            audioEngine.load(url: url)
            isVideoMode = false
            showVideoArea = false
        }
        requestPlaybackStart()
    }

    func togglePlayPause() {
        if canPause {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard currentItem != nil, isPlaying == false else { return }
        transportGeneration &+= 1
        resetSpectrumFrameRate()
        requestPlaybackStart()
    }

    func pause() {
        guard canPause else { return }
        transportGeneration &+= 1
        cancelPendingPlaybackStart()
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
        cancelPendingPlaybackStart()
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
        deferredPlaybackRequestID = nil
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

    // 再生速度変更に起因する周波数欠落バグの切り分け用。エンジンを丸ごと
    // 作り直すが、再生位置・再生状態・各種設定はエンジン側が引き継ぐので
    // ViewModel の公開状態はそのままでよい
    func resetAudioEngine() {
        if !isVideoMode {
            cancelPendingPlaybackStart()
            playbackGeneration &+= 1
        }
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

    private func closeVideoSession() {
        pendingVideoLoad = nil
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

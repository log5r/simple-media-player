import Foundation

extension PlayerViewModel {
    func setVisualizerBandCount(_ count: Int?) {
        analyzer.setBandCount(count)
    }

    func setVisualizerResponseMode(_ mode: VisualizerResponseMode) {
        analyzer.setResponseMode(mode)
    }

    func updateClock() {
        timer?.invalidate()
        timer = nil
        playbackClockInterval = nil
        guard clockEnabled else { return }
        // .common モードで登録しないと、マウストラッキング中（ボタン長押しなど）に
        // RunLoop が .eventTracking モードになりタイマーが発火しない
        // After the engine's asynchronous pause, synchronize the clock once, then rest.
        // In the background only the position is kept roughly current; track ends arrive through onFinished.
        let interval = isPlaying ? (isInBackground ? 1.0 : 1.0 / 30) : 0.5
        if isPlaying { playbackClockInterval = interval }
        let timer = Timer(timeInterval: interval, repeats: isPlaying) { [weak self] timer in
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

    func acceptAudioFrame(_ frame: AudioFrameData) {
        audioFrame = frame
        updateVisualizerIdle()
        guard frame.isPlaying else {
            resetSpectrumFrameRate()
            return
        }
        if let frameRate = spectrumFrameRateCounter.recordFrame(at: ProcessInfo.processInfo.systemUptime) {
            spectrumFrameRate = frameRate
        }
    }

    func resetSpectrumFrameRate() {
        spectrumFrameRate = 0
        spectrumFrameRateCounter.reset()
    }

    func updateVisualizerIdle() {
        let idle = isPlaying == false && audioFrame.isSilent
        if isVisualizerIdle != idle { isVisualizerIdle = idle }
    }

    /// Registers a view on screen that draws `audioFrame`. Registering the same ID again has no effect.
    func addVisualizationConsumer(_ id: UUID) {
        visualizationConsumers.insert(id)
        updateVisualizationSuspension()
    }

    func removeVisualizationConsumer(_ id: UUID) {
        visualizationConsumers.remove(id)
        updateVisualizationSuspension()
    }

    /// Only the background phase counts: on iOS a locked device or another app in front, on macOS a hidden
    /// app. Inactive scenes can still be seen, such as an iPhone app behind Control Center or in the app
    /// switcher.
    func setInBackground(_ background: Bool) {
        guard isInBackground != background else { return }
        isInBackground = background
        updateVisualizationSuspension()
        guard isPlaying else { return }
        updateClock()
        // The 1 Hz clock may be up to a second behind; show the current position at once.
        if background == false { synchronizePlaybackClock() }
    }

    func updateVisualizationSuspension() {
        let suspended = isInBackground || visualizationConsumers.isEmpty
        guard isVisualizationSuspended != suspended else { return }
        isVisualizationSuspended = suspended
        analyzer.setAnalysisEnabled(suspended == false)
        guard suspended else { return }
        // No frames arrive while suspended. Drop the last one so a returning display does not freeze on it.
        audioFrame = .silent(
            bandCount: audioFrame.bandsL.count, currentTime: audioFrame.currentTime, isPlaying: isPlaying
        )
        updateVisualizerIdle()
        resetSpectrumFrameRate()
    }
}

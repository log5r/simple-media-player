import Foundation

extension PlayerViewModel {
    func cancelPendingPlaybackStart() {
        pendingPlaybackStart?.cancel()
        pendingPlaybackStart = nil
        isPreparingPlayback = false
    }

    func requestPlaybackStart() {
        cancelPendingPlaybackStart()
        guard let itemID = currentItem?.id else { return }
        if audioSession.isReady, pendingVideoLoad == nil {
            playPreparedMedia()
            return
        }
        let generation = playbackGeneration
        let transport = transportGeneration
        let videoLoad = pendingVideoLoad
        let audioSession = audioSession
        isPreparingPlayback = true
        pendingPlaybackStart = Task { [weak self] in
            do {
                try await audioSession.prepare()
                await videoLoad?.value
                guard !Task.isCancelled, let self,
                      playbackGeneration == generation, transportGeneration == transport,
                      currentItem?.id == itemID else { return }
                pendingPlaybackStart = nil
                isPreparingPlayback = false
                playPreparedMedia()
            } catch {
                guard !Task.isCancelled, let self,
                      playbackGeneration == generation, transportGeneration == transport,
                      currentItem?.id == itemID else { return }
                pendingPlaybackStart = nil
                isPreparingPlayback = false
                errorMessage = error.localizedDescription
                isPlaying = false
            }
        }
    }

    private func playPreparedMedia() {
        if isVideoMode {
            videoService.play()
        } else {
            audioEngine.play()
        }
        isPlaying = true
    }
}

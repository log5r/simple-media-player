#if os(iOS)
import SwiftUI

enum MusicLibraryAccessProblem: Identifiable {
    case denied
    case restricted

    var id: Self { self }

    var message: String {
        switch self {
        case .denied:
            L10n.string("Music access is not allowed. Allow access in Settings to use songs from your Music library.")
        case .restricted:
            L10n.string("Music access is restricted on this device.")
        }
    }
}

extension MainView {
    func withMusicLibraryPresentations<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $musicPickerMode) { mode in
                MusicLibraryPicker(
                    mode: mode,
                    onPick: { tracks in handleMusicLibrarySelection(tracks, mode: mode) },
                    onCancel: { musicPickerMode = nil }
                )
                .ignoresSafeArea()
            }
            .alert("Music Library", isPresented: Binding(
                get: { musicAccessProblem != nil }, set: { if !$0 { musicAccessProblem = nil } }
            ), presenting: musicAccessProblem) { problem in
                if problem == .denied, let settingsURL = MusicLibraryAccess.settingsURL {
                    Button("Open Settings") { openURL(settingsURL) }
                }
                Button("OK", role: .cancel) {}
            } message: { problem in
                Text(problem.message)
            }
            .alert("Music Library", isPresented: Binding(
                get: { musicResultMessage != nil }, set: { if !$0 { musicResultMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(musicResultMessage ?? "")
            }
    }

    func requestMusicLibraryPicker(_ mode: MusicLibraryPickerMode) {
        guard libraryService.musicLibraryPreparation == nil else { return }
        Task {
            switch await MusicLibraryAccess.requestAuthorization() {
            case .authorized:
                #if targetEnvironment(simulator)
                // The picker is an app extension that the Simulator cannot host; it reports an internal error.
                musicResultMessage = L10n.string("The Music library picker is not available in the Simulator.")
                #else
                musicPickerMode = mode
                #endif
            case .denied:
                musicAccessProblem = .denied
            case .restricted:
                musicAccessProblem = .restricted
            }
        }
    }

    func handleMusicLibrarySelection(_ tracks: [MusicLibraryTrack], mode: MusicLibraryPickerMode) {
        musicPickerMode = nil
        switch mode {
        case .play:
            if let track = tracks.first { playMusicLibraryTrack(track) }
        case .importing:
            importMusicLibraryTracks(tracks)
        }
    }

    /// The exported copy plays only if it is still the latest Music selection (from any scene) and no
    /// transport action (play, pause, resume, stop, clear) happened meanwhile; a late result must not
    /// override what the user did in between. A failure is reported unless a newer Music request, another
    /// track, or clearing the player superseded it.
    func playMusicLibraryTrack(_ track: MusicLibraryTrack) {
        let request = player.beginDeferredPlaybackRequest()
        Task {
            switch await libraryService.prepareMusicLibraryPlayback(of: track) {
            case let .ready(session):
                guard player.canApply(request) else {
                    session.end()
                    return
                }
                browsingState.playingListName = L10n.string("Music")
                player.play(transientSession: session)
            case let .failed(message):
                guard player.isLatestDeferredRequest(request) else { return }
                musicResultMessage = message
            case .cancelled:
                break
            }
        }
    }

    func importMusicLibraryTracks(_ tracks: [MusicLibraryTrack]) {
        Task {
            guard let result = await libraryService.importMusicLibraryTracks(
                tracks, into: modelContext, existingItems: items
            ) else { return }
            musicResultMessage = result.summary
        }
    }
}
#endif

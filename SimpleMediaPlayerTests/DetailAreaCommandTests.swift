#if os(iOS)
import Foundation
import SwiftUI
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct DetailAreaCommandTests {
    @Test(arguments: [true, false], [true, false])
    func backToListDismissesFullScreenVideoAndRetainsPlayback(
        _ showsInlineVideo: Bool, _ isPaused: Bool
    ) async {
        let movie = makeMovie(title: "Current movie")
        let queue = [makeMovie(title: "Previous movie"), movie, makeMovie(title: "Next movie")]
        let movieURL = URL(fileURLWithPath: "/tmp/detail-command-movie.mov")
        let fixture = makePlayerFixture(urlsByID: [movie.id: movieURL])
        fixture.player.play(item: movie, in: queue)
        for _ in 0..<20 {
            await Task.yield()
            if fixture.player.isPlaying { break }
        }
        #expect(fixture.player.isPlaying)
        if isPaused { fixture.player.pause() }
        fixture.player.seek(to: 12)
        fixture.player.showVideoArea = showsInlineVideo
        let generation = fixture.player.playbackGeneration
        let browsingState = LibraryBrowsingState()
        browsingState.showsVideoFullScreen = true

        // Avoid reading uninstalled layout state through the unrelated inline EQ preference.
        // This preference is restored without yielding the MainActor during the command checks.
        let defaults = UserDefaults.standard
        let previousEqualizerPreference = defaults.object(forKey: AppSettingsKey.showEqualizerPanel)
        defaults.set(false, forKey: AppSettingsKey.showEqualizerPanel)
        defer { defaults.set(previousEqualizerPreference, forKey: AppSettingsKey.showEqualizerPanel) }
        let detail = makeDetailArea(player: fixture.player, browsingState: browsingState, queue: queue)
        let actions = detail.appMenuActions

        #expect(actions.videoAreaIsVisible)
        #expect(actions.toggleVideoArea.isEnabled)
        actions.toggleVideoArea()

        #expect(!browsingState.showsVideoFullScreen)
        #expect(!fixture.player.showVideoArea)
        #expect(!detail.appMenuActions.videoAreaIsVisible)
        #expect(fixture.player.currentItem?.id == movie.id)
        #expect(fixture.player.queue.map(\.id) == queue.map(\.id))
        #expect(fixture.player.isVideoMode)
        #expect(fixture.player.isPlaying == !isPaused)
        #expect(fixture.player.isPaused == isPaused)
        #expect(fixture.player.currentTime == 12)
        #expect(fixture.player.playbackGeneration == generation)
        #expect(fixture.video.loadedURLs == [movieURL])
        #expect(fixture.video.playCallCount == 1)
        #expect(fixture.video.pauseCallCount == (isPaused ? 1 : 0))
        #expect(fixture.video.stopCallCount == 0)
        #expect(fixture.video.closeCallCount == 0)
    }

    private func makeMovie(title: String) -> MediaItem {
        MediaItem(title: title, duration: 30, isVideo: true, bookmarkData: Data([1]), fileName: title)
    }

    private func makeDetailArea(
        player: PlayerViewModel, browsingState: LibraryBrowsingState, queue: [MediaItem]
    ) -> DetailAreaView {
        DetailAreaView(
            browsingState: browsingState,
            items: queue,
            allQueue: queue,
            selectedSection: .allVideos,
            activePlaylist: nil,
            title: "All Videos",
            searchText: .constant(""),
            searchFilter: .constant(LibrarySearchFilter()),
            librarySortField: .constant(.dateAdded),
            librarySortDirection: .constant(.ascending),
            showLyricsPanel: .constant(false),
            isImporterPresented: .constant(false),
            selectedItemID: .constant(player.currentItem?.id),
            libraryService: LibraryService(),
            player: player,
            playlists: [],
            addToPlaylist: { _, _ in },
            createPlaylistWithItem: { _ in },
            removeFromPlaylist: { _ in },
            movePlaylistItem: { _, _ in },
            createAACVersion: { _ in },
            canCreateAACVersion: false,
            aacVersionExporter: TransformedTrackExporter(),
            aacVersionSourceTitle: nil,
            createPlaylist: {},
            showAddToPlaylistSheet: {},
            exportToFinder: {},
            requestSaveCopy: { _ in },
            deleteItem: { _ in },
            playItem: { _ in }
        )
    }
}
#endif

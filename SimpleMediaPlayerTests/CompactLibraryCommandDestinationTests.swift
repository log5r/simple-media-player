#if os(iOS)
import Foundation
import SwiftUI
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct CompactLibraryCommandDestinationTests {
    @Test func rootsDoNotUseTheNeutralSelectionsMedia() {
        let state = LibraryBrowsingState()
        #expect(CompactLibraryCommandDestination.current(in: state) == .libraryRoot)

        state.selectPhoneTab(1)

        #expect(state.selection == .library(.allSongs))
        #expect(CompactLibraryCommandDestination.current(in: state) == .playlistRoot)
    }

    @Test func savedTabsAndParentCategoriesAreNotTheDisplayedDestination() {
        let state = LibraryBrowsingState()
        let group = LibraryBrowsingGroup(section: .albums, name: "Album")
        let playlistID = UUID()
        state.openGroup(section: group.section, name: group.name)
        #expect(CompactLibraryCommandDestination.current(in: state) == .library(.group(group)))
        #expect(CompactLibraryCommandDestination.current(in: state) != .library(.section(.albums)))

        state.navigatePlaylists(to: [playlistID])

        #expect(CompactLibraryCommandDestination.current(in: state) == .playlist(playlistID))
        #expect(CompactLibraryCommandDestination.current(in: state) != .library(.group(group)))

        state.selectPhoneTab(3)

        #expect(CompactLibraryCommandDestination.current(in: state) == .search)
        #expect(CompactLibraryCommandDestination.current(in: state) != .playlist(playlistID))

        state.selectPhoneTab(0)

        #expect(CompactLibraryCommandDestination.current(in: state) == .library(.group(group)))
    }

    @Test func videosAndSearchDoNotInheritSavedLibraryRoutes() {
        let state = LibraryBrowsingState()
        state.navigateLibrary(to: [.section(.allSongs)])
        state.selectPhoneTab(2)

        #expect(CompactLibraryCommandDestination.current(in: state) == .videos)

        state.selectPhoneTab(3)

        #expect(CompactLibraryCommandDestination.current(in: state) == .search)

        state.selectPhoneTab(0)

        #expect(CompactLibraryCommandDestination.current(in: state) == .library(.section(.allSongs)))
    }

    @Test(arguments: [false, true])
    func backToListDismissesInheritedFullScreenVideoAndRetainsPlayback(_ showsDeck: Bool) async {
        let fixture = await makePlayingMovieFixture()
        let state = LibraryBrowsingState()
        state.selectPhoneTab(2)
        state.showsVideoFullScreen = true
        let presentation = CompactCommandPresentationState(showsDeck: showsDeck)
        let context = makeContext(
            player: fixture.player, state: state, items: fixture.queue, presentation: presentation
        )
        let generation = fixture.player.playbackGeneration
        fixture.player.seek(to: 12)
        let commands = context.appMenuActions

        #expect(commands.videoAreaIsVisible)
        #expect(commands.toggleVideoArea.isEnabled)
        commands.toggleVideoArea()

        #expect(!state.showsVideoFullScreen)
        #expect(!presentation.showsDeck)
        #expect(!fixture.player.showVideoArea)
        #expect(!context.appMenuActions.videoAreaIsVisible)
        #expect(fixture.player.currentItem?.id == fixture.queue.first?.id)
        #expect(fixture.player.queue.map(\.id) == fixture.queue.map(\.id))
        #expect(fixture.player.isPlaying)
        #expect(!fixture.player.isPaused)
        #expect(fixture.player.isVideoMode)
        #expect(fixture.player.currentTime == 12)
        #expect(fixture.player.playbackGeneration == generation)
        #expect(fixture.video.loadedURLs.count == 1)
        #expect(fixture.video.playCallCount == 1)
        #expect(fixture.video.pauseCallCount == 0)
        #expect(fixture.video.stopCallCount == 0)
        #expect(fixture.video.closeCallCount == 0)
    }

    @Test func inheritedFullScreenVideoDisablesOtherPresentationCommands() async {
        let fixture = await makePlayingMovieFixture()
        let state = LibraryBrowsingState()
        let playlist = Playlist(name: "Playlist")
        state.navigatePlaylists(to: [playlist.id])
        let context = makeContext(
            player: fixture.player, state: state, items: fixture.queue,
            presentation: CompactCommandPresentationState(), playlist: playlist
        )
        let unobscuredCommands = context.appMenuActions
        #expect(unobscuredCommands.showSettings.isEnabled)
        #expect(unobscuredCommands.exportToFinder.isEnabled)
        #expect(unobscuredCommands.createPlaylist.isEnabled)
        #expect(unobscuredCommands.addTracksToPlaylist.isEnabled)
        #expect(unobscuredCommands.beginMultipleEdit.isEnabled)
        #expect(unobscuredCommands.toggleEqualizer.isEnabled)
        state.showsVideoFullScreen = true
        unobscuredCommands.showSettings()
        unobscuredCommands.toggleEqualizer()
        #expect(!state.showsSettings)
        #expect(!state.showsEqualizer)
        let commands = context.appMenuActions

        #expect(!commands.showSettings.isEnabled)
        #expect(!commands.exportToFinder.isEnabled)
        #expect(!commands.createPlaylist.isEnabled)
        #expect(!commands.addTracksToPlaylist.isEnabled)
        #expect(!commands.beginMultipleEdit.isEnabled)
        #expect(!commands.toggleLyrics.isEnabled)
        #expect(!commands.toggleEqualizer.isEnabled)
        commands.showSettings()
        commands.toggleEqualizer()
        unobscuredCommands.showSettings()
        unobscuredCommands.toggleEqualizer()
        #expect(!state.showsSettings)
        #expect(!state.showsEqualizer)

        state.isBulkEditMode = true
        state.bulkSelection.toggle(fixture.queue[0].id)
        let bulkCommands = context.appMenuActions
        #expect(!bulkCommands.editSelectedMedia.isEnabled)
        #expect(!bulkCommands.cancelMultipleEdit.isEnabled)
        bulkCommands.editSelectedMedia()
        bulkCommands.cancelMultipleEdit()
        #expect(state.isBulkEditMode)
        #expect(state.bulkEditSession == nil)
        #expect(state.bulkSelection.contains(fixture.queue[0].id))
    }

    @Test func commandsCapturedBeforeChangingTabsCannotDismissOrPauseTheNewDestination() async {
        let fixture = await makePlayingMovieFixture()
        let state = LibraryBrowsingState()
        state.selectPhoneTab(2)
        state.showsVideoFullScreen = true
        let presentation = CompactCommandPresentationState()
        let context = makeContext(
            player: fixture.player, state: state, items: fixture.queue, presentation: presentation
        )
        let commands = context.appMenuActions
        #expect(commands.toggleVideoArea.isEnabled)
        #expect(commands.playPause.isEnabled)
        state.selectPhoneTab(1)

        commands.toggleVideoArea()
        commands.playPause()

        #expect(state.showsVideoFullScreen)
        #expect(!presentation.showsDeck)
        #expect(fixture.player.showVideoArea)
        #expect(fixture.player.isPlaying)
        #expect(fixture.video.pauseCallCount == 0)
    }

    private func makePlayingMovieFixture() async -> CompactPlayingMovieFixture {
        let movie = MediaItem(title: "Movie", duration: 30, isVideo: true, bookmarkData: Data([1]), fileName: "Movie")
        let next = MediaItem(
            title: "Next movie", duration: 30, isVideo: true, bookmarkData: Data([2]), fileName: "Next"
        )
        let fixture = makePlayerFixture(urlsByID: [movie.id: URL(fileURLWithPath: "/tmp/compact-command-movie.mov")])
        let queue = [movie, next]
        fixture.player.play(item: movie, in: queue)
        for _ in 0..<20 {
            await Task.yield()
            if fixture.player.isPlaying { break }
        }
        #expect(fixture.player.isPlaying)
        return CompactPlayingMovieFixture(player: fixture.player, video: fixture.video, queue: queue)
    }

    private func makeContext(
        player: PlayerViewModel, state: LibraryBrowsingState, items: [MediaItem],
        presentation: CompactCommandPresentationState, playlist: Playlist? = nil
    ) -> CompactLibraryCommandContext {
        CompactLibraryCommandContext(
            destination: .current(in: state), browsingState: state, player: player,
            actions: IPhoneLibraryActions(
                createPlaylist: { Playlist(name: "New playlist") }, renamePlaylist: { _, _ in },
                deletePlaylist: { _ in }, addToPlaylist: { _, _ in }, createPlaylistWithItem: { _ in },
                addItems: { _, _ in }, removeItem: { _, _ in }, moveItems: { _, _, _ in },
                createAACVersion: { _ in }, exportItems: { _ in }, deleteItem: { _ in },
                showAddTracks: { _ in }, requestSaveCopy: { _ in }
            ),
            canEditLibrary: true, supportsMultipleEdit: true, playlist: playlist,
            queue: { items }, selectedItem: { items.first }, playItem: { player.play(item: $0, in: items) },
            showsDeck: Binding(get: { presentation.showsDeck }, set: { presentation.showsDeck = $0 })
        )
    }
}

@MainActor
private struct CompactPlayingMovieFixture {
    let player: PlayerViewModel
    let video: FakeVideoService
    let queue: [MediaItem]
}

@MainActor
private final class CompactCommandPresentationState {
    var showsDeck: Bool

    init(showsDeck: Bool = false) {
        self.showsDeck = showsDeck
    }
}
#endif

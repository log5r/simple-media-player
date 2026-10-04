import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryBrowsingStateTests {
    @Test(arguments: [LibrarySection.albums, .artists, .genres])
    func compactGroupRouteAndExpandedDestinationAgree(section: LibrarySection) {
        let state = LibraryBrowsingState()
        let group = LibraryBrowsingGroup(section: section, name: "Example")

        state.navigateLibrary(to: [.section(section), .group(group)])

        #expect(state.selection == .library(section))
        #expect(state.group == group)
        #expect(state.phoneTab == 0)

        state.closeGroup()

        #expect(state.libraryPath == [.section(section)])
        #expect(state.group == nil)
        #expect(state.selection == .library(section))
    }

    @Test func expandedAlbumSelectionProducesCompactNavigationPath() {
        let state = LibraryBrowsingState()

        state.openGroup(section: .albums, name: "Album")

        #expect(state.libraryPath == [
            .section(.albums), .group(LibraryBrowsingGroup(section: .albums, name: "Album"))
        ])
        state.navigateLibrary(to: [.section(.albums)])
        #expect(state.group == nil)
        #expect(state.selection == .library(.albums))
    }

    @Test func tabsRestoreTheirNavigationDestinationsWithoutLosingSearchOrSort() {
        let state = LibraryBrowsingState()
        let playlistID = UUID()
        state.openGroup(section: .artists, name: "Artist")
        state.searchText = "Query"
        state.searchFilter.genre = "Jazz"
        state.sortField = .title
        state.sortDirection = .descending

        state.navigatePlaylists(to: [playlistID])
        state.selectPhoneTab(3)
        #expect(state.selection == .library(.allSongs))
        #expect(state.group == nil)
        state.selectPhoneTab(1)
        #expect(state.selection == .playlist(playlistID))
        state.selectPhoneTab(0)

        #expect(state.group == LibraryBrowsingGroup(section: .artists, name: "Artist"))
        #expect(state.searchText == "Query")
        #expect(state.searchFilter.genre == "Jazz")
        #expect(state.sortField == .title)
        #expect(state.sortDirection == .descending)
    }

    @Test func returningFromAPlaylistClearsItsExpandedDestinationAndListInteraction() {
        let state = LibraryBrowsingState()
        let playlistID = UUID()
        let selectedID = UUID()
        state.navigatePlaylists(to: [playlistID])
        state.selectedItemID = selectedID
        state.scrollItemID = selectedID
        state.isBulkEditMode = true
        state.bulkSelection.select([selectedID])

        state.navigatePlaylists(to: [])

        #expect(state.playlistPath.isEmpty)
        #expect(state.phoneTab == 1)
        #expect(state.selection == .library(.allSongs))
        #expect(state.group == nil)
        #expect(state.selectedItemID == nil)
        #expect(state.scrollItemID == nil)
        #expect(state.isBulkEditMode == false)
        #expect(state.bulkSelection.ids.isEmpty)
    }

    @Test func emptyPlaylistTabUsesRootDestinationAndPreservesTheLibraryRoute() {
        let state = LibraryBrowsingState()
        let group = LibraryBrowsingGroup(section: .albums, name: "Album")
        state.openGroup(section: group.section, name: group.name)

        state.selectPhoneTab(1)

        #expect(state.playlistPath.isEmpty)
        #expect(state.phoneTab == 1)
        #expect(state.selection == .library(.allSongs))
        #expect(state.group == nil)

        state.selectPhoneTab(0)

        #expect(state.selection == .library(.albums))
        #expect(state.group == group)
        #expect(state.libraryPath == [.section(.albums), .group(group)])
    }

    @Test func reselectingSidebarCategoryLeavesItsGroupAndClearsListInteraction() {
        let state = LibraryBrowsingState()
        let selectedID = UUID()
        state.openGroup(section: .albums, name: "Album")
        state.selectedItemID = selectedID
        state.scrollItemID = selectedID
        state.isBulkEditMode = true
        state.bulkSelection.select([selectedID])

        state.select(.library(.albums))

        #expect(state.group == nil)
        #expect(state.libraryPath == [.section(.albums)])
        #expect(state.selectedItemID == nil)
        #expect(state.scrollItemID == nil)
        #expect(state.isBulkEditMode == false)
        #expect(state.bulkSelection.ids.isEmpty)
    }

    @Test func deletingAnInactivePlaylistRemovesItsCompactRoute() {
        let state = LibraryBrowsingState()
        let id = UUID()
        state.select(.playlist(id))
        state.selectPhoneTab(2)

        state.removePlaylist(id)

        #expect(state.playlistPath.isEmpty)
        #expect(state.selection == .library(.allVideos))
    }

    @Test func deletingTheBrowsedPlaylistReturnsToThePlaylistTabRoot() {
        let state = LibraryBrowsingState()
        let id = UUID()
        state.select(.playlist(id))

        state.removePlaylist(id)

        #expect(state.playlistPath.isEmpty)
        #expect(state.phoneTab == 1)
        #expect(state.selection == .library(.allSongs))
    }

    @Test func queryDeletionClearsPlaylistRoutesAndPendingAlerts() {
        let state = LibraryBrowsingState()
        let removed = Playlist(name: "Removed")
        let remaining = Playlist(name: "Remaining")
        state.select(.playlist(removed.id))
        state.playlistToRename = removed
        state.playlistToDelete = removed

        state.retainPlaylists(ids: [remaining.id])

        #expect(state.playlistPath.isEmpty)
        #expect(state.selection == .library(.allSongs))
        #expect(state.phoneTab == 1)
        #expect(state.playlistToRename == nil)
        #expect(state.playlistToDelete == nil)
    }

    @Test func queryDeletionPreservesAnotherTabsDestinationAndExistingPlaylistAlert() {
        let state = LibraryBrowsingState()
        let removed = Playlist(name: "Removed")
        let remaining = Playlist(name: "Remaining")
        state.select(.playlist(removed.id))
        state.selectPhoneTab(2)
        state.playlistToRename = remaining

        state.retainPlaylists(ids: [remaining.id])

        #expect(state.playlistPath.isEmpty)
        #expect(state.selection == .library(.allVideos))
        #expect(state.playlistToRename === remaining)
    }

    @Test func deletedItemsInvalidateSelectionAndPendingEditorTargets() {
        let state = LibraryBrowsingState()
        let removed = makeItem("Removed")
        let remaining = makeItem("Remaining")
        state.selectedItemID = removed.id
        state.scrollItemID = removed.id
        state.infoItem = removed
        state.lyricsItem = removed
        state.artworkPreview = LibraryArtworkPreview(itemID: removed.id, data: Data([1]))
        state.deleteConfirmationItem = removed
        state.bulkEditSession = BulkMetadataEditSession(items: [removed])
        state.bulkSelection.select([removed.id, remaining.id])

        state.retainItems(ids: [remaining.id])

        #expect(state.selectedItemID == nil)
        #expect(state.scrollItemID == nil)
        #expect(state.infoItem == nil)
        #expect(state.lyricsItem == nil)
        #expect(state.artworkPreview == nil)
        #expect(state.deleteConfirmationItem == nil)
        #expect(state.bulkEditSession == nil)
        #expect(state.bulkSelection.ids == [remaining.id])
    }

    @Test func partialDeletionDismissesTheBulkEditorAndRetainsSurvivingSelection() {
        let state = LibraryBrowsingState()
        let removed = makeItem("Removed")
        let remaining = makeItem("Remaining")
        state.bulkEditSession = BulkMetadataEditSession(items: [removed, remaining])
        state.isBulkEditMode = true
        state.bulkSelection.select([removed.id, remaining.id])

        state.retainItems(ids: [remaining.id])

        #expect(state.bulkEditSession == nil)
        #expect(state.isBulkEditMode)
        #expect(state.bulkSelection.ids == [remaining.id])
    }

    @Test func validItemsKeepEditingSessionAndSelectionDuringProjectionReplacement() throws {
        let state = LibraryBrowsingState()
        let item = makeItem("Item")
        state.selectedItemID = item.id
        state.scrollItemID = item.id
        state.infoItem = item
        state.lyricsItem = item
        state.artworkPreview = LibraryArtworkPreview(itemID: item.id, data: Data([1]))
        state.bulkEditSession = BulkMetadataEditSession(items: [item])
        let sessionID = try #require(state.bulkEditSession?.id)
        state.isBulkEditMode = true
        state.bulkSelection.select([item.id])

        state.retainItems(ids: [item.id])

        #expect(state.selectedItemID == item.id)
        #expect(state.scrollItemID == item.id)
        #expect(state.infoItem === item)
        #expect(state.lyricsItem === item)
        #expect(state.artworkPreview?.itemID == item.id)
        #expect(state.artworkPreview?.data == Data([1]))
        #expect(state.bulkEditSession?.id == sessionID)
        #expect(state.isBulkEditMode)
        #expect(state.bulkSelection.ids == [item.id])
    }

    @Test func albumPlaybackQueueKeepsTrackOrderAcrossLayoutTransitions() {
        let state = LibraryBrowsingState()
        let first = makeItem("First")
        first.album = "Album"
        first.trackNumber = "1"
        let second = makeItem("Second")
        second.album = "Album"
        second.trackNumber = "2"
        let unrelated = makeItem("Other")
        unrelated.album = "Other Album"
        state.openGroup(section: .albums, name: "Album")

        #expect(state.playbackQueue(from: [second, unrelated, first]).map(\.id) == [first.id, second.id])

        state.navigateLibrary(to: state.libraryPath)

        #expect(state.playbackQueue(from: [second, unrelated, first]).map(\.id) == [first.id, second.id])
    }

    @Test func artistGroupKeepsTheUsersSortOrderWhenBuildingItsQueue() {
        let state = LibraryBrowsingState()
        let first = makeItem("First")
        first.artist = "Artist"
        let second = makeItem("Second")
        second.artist = "Artist"
        let unrelated = makeItem("Other")
        unrelated.artist = "Another Artist"
        state.openGroup(section: .artists, name: "Artist")

        #expect(state.playbackQueue(from: [second, unrelated, first]).map(\.id) == [second.id, first.id])
    }

    private func makeItem(_ title: String) -> MediaItem {
        MediaItem(title: title, duration: 120, isVideo: false, bookmarkData: Data(), fileName: "song.wav")
    }
}

import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryBrowsingGroupInvalidationTests {
    @Test(arguments: [LibrarySection.albums, .artists, .genres], [false, true])
    func deletingTheLastGroupItemsReturnsToTheCategory(section: LibrarySection, libraryIsEmpty: Bool) throws {
        let state = LibraryBrowsingState()
        let removed = makeItem("Removed", groupName: "Group")
        let remaining = makeItem("Remaining", groupName: "Other")
        let group = LibraryBrowsingGroup(section: section, name: "Group")
        state.openGroup(section: section, name: group.name)
        state.selectedItemID = removed.id
        state.scrollItemID = removed.id
        state.isBulkEditMode = true
        state.bulkSelection.select([removed.id])
        let remainingItems = libraryIsEmpty ? [] : [remaining]

        state.retainItems(ids: Set(remainingItems.map(\.id)))
        let missing = try #require(state.missingLibraryGroup(in: remainingItems))
        state.removeLibraryGroup(missing)

        #expect(state.libraryPath == [.section(section)])
        #expect(state.selection == .library(section))
        #expect(state.group == nil)
        #expect(state.phoneTab == 0)
        #expect(state.selectedItemID == nil)
        #expect(state.scrollItemID == nil)
        #expect(state.isBulkEditMode == false)
        #expect(state.bulkSelection.ids.isEmpty)
    }

    @Test(arguments: [LibrarySection.albums, .artists, .genres], [1, 3])
    func removingAnInactiveGroupPreservesTheOtherTabsState(section: LibrarySection, tab: Int) throws {
        let state = LibraryBrowsingState()
        let remaining = makeItem("Remaining", groupName: "Other")
        let playlistID = UUID()
        state.openGroup(section: section, name: "Group")
        state.navigatePlaylists(to: [playlistID])
        state.selectPhoneTab(tab)
        let activeSelection = state.selection
        state.selectedItemID = remaining.id
        state.scrollItemID = remaining.id
        state.isBulkEditMode = true
        state.bulkSelection.select([remaining.id])

        let missing = try #require(state.missingLibraryGroup(in: [remaining]))
        state.removeLibraryGroup(missing)

        #expect(state.libraryPath == [.section(section)])
        #expect(state.selection == activeSelection)
        #expect(state.phoneTab == tab)
        #expect(state.playlistPath == [playlistID])
        #expect(state.selectedItemID == remaining.id)
        #expect(state.scrollItemID == remaining.id)
        #expect(state.isBulkEditMode)
        #expect(state.bulkSelection.ids == [remaining.id])

        state.selectPhoneTab(0)

        #expect(state.selection == .library(section))
        #expect(state.group == nil)
    }

    @Test(arguments: [LibrarySection.albums, .artists, .genres])
    func survivingGroupsIgnoreTheCurrentSearchAndFilter(section: LibrarySection) {
        let state = LibraryBrowsingState()
        let item = makeItem("Item", groupName: "Group")
        let group = LibraryBrowsingGroup(section: section, name: "Group")
        state.openGroup(section: section, name: group.name)
        state.searchText = "No matching item"
        state.searchFilter.title = "No matching title"

        let missing = state.missingLibraryGroup(in: [item])

        #expect(missing == nil)
        #expect(state.group == group)
        #expect(state.libraryPath == [.section(section), .group(group)])
    }

    @Test(arguments: [LibrarySection.albums, .artists, .genres])
    func videosWithMatchingMetadataDoNotKeepAnAudioGroupAlive(section: LibrarySection) throws {
        let state = LibraryBrowsingState()
        let video = makeItem("Video", groupName: "Group")
        video.isVideo = true
        state.openGroup(section: section, name: "Group")

        let missing = try #require(state.missingLibraryGroup(in: [video]))
        state.removeLibraryGroup(missing)

        #expect(state.group == nil)
        #expect(state.libraryPath == [.section(section)])
        #expect(state.selection == .library(section))
    }

    @Test(arguments: [LibrarySection.albums, .artists, .genres])
    func renamingTheLastGroupItemInvalidatesTheRouteWithoutDeletingTheItem(section: LibrarySection) throws {
        let state = LibraryBrowsingState()
        let item = makeItem("Item", groupName: "Group")
        state.openGroup(section: section, name: "Group")
        #expect(state.missingLibraryGroup(in: [item]) == nil)

        item.album = "Renamed"
        item.artist = "Renamed"
        item.genre = "Renamed"
        let missing = try #require(state.missingLibraryGroup(in: [item]))
        state.removeLibraryGroup(missing)

        #expect(state.group == nil)
        #expect(state.selection == .library(section))
        #expect(state.libraryPath == [.section(section)])
    }

    @Test func staleGroupRemovalPreservesANewlyOpenedRoute() throws {
        let state = LibraryBrowsingState()
        state.openGroup(section: .albums, name: "Removed")
        let missing = try #require(state.missingLibraryGroup(in: []))
        let replacement = LibraryBrowsingGroup(section: .albums, name: "Replacement")
        state.openGroup(section: replacement.section, name: replacement.name)

        state.removeLibraryGroup(missing)

        #expect(state.group == replacement)
        #expect(state.libraryPath == [.section(.albums), .group(replacement)])
    }

    private func makeItem(_ title: String, groupName: String) -> MediaItem {
        MediaItem(
            title: title, artist: groupName, album: groupName, genre: groupName,
            duration: 120, isVideo: false, bookmarkData: Data(), fileName: "song.wav"
        )
    }
}

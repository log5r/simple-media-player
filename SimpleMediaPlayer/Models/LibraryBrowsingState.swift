import Foundation
import Observation

struct LibraryBrowsingGroup: Hashable {
    let section: LibrarySection
    let name: String

    func contains(_ item: MediaItem) -> Bool {
        switch section {
        case .albums: item.displayAlbum == name
        case .artists: item.displayArtist == name
        case .genres: item.displayGenre == name
        case .allSongs, .allVideos: false
        }
    }

    func playbackQueue(from items: [MediaItem]) -> [MediaItem] {
        let groupedItems = items.filter(contains)
        if section == .albums { return LibraryAlbum.grouped(groupedItems).first?.tracks ?? [] }
        return groupedItems
    }
}

enum LibraryBrowsingRoute: Hashable {
    case section(LibrarySection)
    case group(LibraryBrowsingGroup)
}

struct BulkMetadataEditSession: Identifiable {
    let id = UUID()
    let items: [MediaItem]
}

struct LibraryArtworkPreview: Identifiable {
    let itemID: UUID
    let data: Data

    var id: UUID { itemID }
}

/// A scene owns this state above the compact/expanded layout boundary.
/// Changing that boundary never changes a browsing destination or an editing session.
@MainActor
@Observable
final class LibraryBrowsingState {
    var selection: SidebarSelection = .library(.allSongs)
    var searchText = LibraryListUITestFixture.searchText
    var searchFilter = LibrarySearchFilter()
    var sortField = LibrarySortField.dateAdded
    var sortDirection = LibrarySortDirection.ascending
    var selectedItemID: UUID?
    var isBulkEditMode = false
    let bulkSelection = BulkMediaSelectionState()
    var playingListName = L10n.string("All Songs")
    private(set) var phoneTab = 0
    private(set) var libraryPath: [LibraryBrowsingRoute] = []
    private(set) var playlistPath: [UUID] = []
    private(set) var group: LibraryBrowsingGroup?
    var scrollItemID: UUID?
    var albumScrollID: String?

    var infoItem: MediaItem?
    var lyricsItem: MediaItem?
    var artworkPreview: LibraryArtworkPreview?
    var panelContent = PanelContent.lyrics
    var deleteConfirmationItem: MediaItem?
    var bulkEditSession: BulkMetadataEditSession?
    var showsSettings = false
    var showsFilters = false
    var showsDetails = false
    var showsEqualizer = false
    var showsVideoFullScreen = false
    var playlistToRename: Playlist?
    var playlistToDelete: Playlist?
    var nameDraft = ""

    /// Used by the sidebar and commands. Re-selecting the category returns to its root.
    func select(_ destination: SidebarSelection) {
        let changed = selection != destination || group != nil
        let previousPhoneTab = phoneTab
        selection = destination
        group = nil
        switch destination {
        case let .library(section):
            phoneTab = section == .allVideos ? 2 : 0
            libraryPath = section == .allVideos ? [] : [.section(section)]
        case let .playlist(id):
            phoneTab = 1
            playlistPath = [id]
        }
        if changed || phoneTab != previousPhoneTab { resetListInteraction() }
    }

    func selectPhoneTab(_ tab: Int) {
        guard phoneTab != tab else { return }
        phoneTab = tab
        switch tab {
        case 0:
            applyLibraryPath()
        case 1:
            applyPlaylistPath()
        case 2:
            selection = .library(.allVideos)
            group = nil
        default:
            selection = .library(.allSongs)
            group = nil
        }
        resetListInteraction()
    }

    func navigateLibrary(to path: [LibraryBrowsingRoute]) {
        guard libraryPath != path else { return }
        libraryPath = path
        phoneTab = 0
        applyLibraryPath()
        resetListInteraction()
    }

    func navigatePlaylists(to path: [UUID]) {
        guard playlistPath != path else { return }
        playlistPath = path
        phoneTab = 1
        applyPlaylistPath()
        resetListInteraction()
    }

    func openGroup(section: LibrarySection, name: String) {
        let destination = LibraryBrowsingGroup(section: section, name: name)
        guard group != destination else { return }
        selection = .library(section)
        phoneTab = 0
        group = destination
        libraryPath = [.section(section), .group(destination)]
        resetListInteraction()
    }

    func closeGroup() {
        guard let group else { return }
        select(.library(group.section))
    }

    /// Validate the saved route against the full library, never a filtered projection.
    func missingLibraryGroup(in items: [MediaItem]) -> LibraryBrowsingGroup? {
        guard case let .group(group)? = libraryPath.last,
              items.contains(where: { $0.isVideo == false && group.contains($0) }) == false else { return nil }
        return group
    }

    func removeLibraryGroup(_ removedGroup: LibraryBrowsingGroup) {
        guard let index = libraryPath.firstIndex(of: .group(removedGroup)) else { return }
        libraryPath.removeSubrange(index...)
        if group == removedGroup {
            selection = .library(removedGroup.section)
            group = nil
            resetListInteraction()
        }
    }

    func removePlaylist(_ id: UUID) {
        let staysOnPlaylistTab = phoneTab == 1
        playlistPath.removeAll { $0 == id }
        if selection == .playlist(id) {
            selection = .library(.allSongs)
            group = nil
            phoneTab = staysOnPlaylistTab ? 1 : 0
            resetListInteraction()
        }
    }

    /// A deletion in another scene must also remove saved routes and pending alerts.
    func retainPlaylists(ids: Set<UUID>) {
        if case let .playlist(id) = selection, ids.contains(id) == false { removePlaylist(id) }
        playlistPath.removeAll { ids.contains($0) == false }
        if let playlistToRename, ids.contains(playlistToRename.id) == false { self.playlistToRename = nil }
        if let playlistToDelete, ids.contains(playlistToDelete.id) == false { self.playlistToDelete = nil }
    }

    func endEditing() {
        isBulkEditMode = false
        bulkSelection.reset()
    }

    func playbackQueue(from items: [MediaItem]) -> [MediaItem] {
        group?.playbackQueue(from: items) ?? items
    }

    /// The full library query is authoritative; a temporarily empty list projection is not.
    func retainItems(ids: Set<UUID>) {
        bulkSelection.retain(ids: ids)
        if let selectedItemID, ids.contains(selectedItemID) == false { self.selectedItemID = nil }
        if let scrollItemID, ids.contains(scrollItemID) == false { self.scrollItemID = nil }
        if let infoItem, ids.contains(infoItem.id) == false { self.infoItem = nil }
        if let lyricsItem, ids.contains(lyricsItem.id) == false { self.lyricsItem = nil }
        if let artworkPreview, ids.contains(artworkPreview.itemID) == false { self.artworkPreview = nil }
        if let deleteConfirmationItem, ids.contains(deleteConfirmationItem.id) == false {
            self.deleteConfirmationItem = nil
        }
        if let bulkEditSession, bulkEditSession.items.contains(where: { ids.contains($0.id) == false }) {
            self.bulkEditSession = nil
        }
        if ids.isEmpty { isBulkEditMode = false }
    }

    private func applyLibraryPath() {
        group = nil
        guard let route = libraryPath.last else {
            selection = .library(.allSongs)
            return
        }
        switch route {
        case let .section(section):
            selection = .library(section)
        case let .group(destination):
            selection = .library(destination.section)
            group = destination
        }
    }

    private func applyPlaylistPath() {
        group = nil
        selection = playlistPath.last.map(SidebarSelection.playlist) ?? .library(.allSongs)
    }

    private func resetListInteraction() {
        scrollItemID = nil
        selectedItemID = nil
        endEditing()
    }
}

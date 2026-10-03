import SwiftUI
#if os(macOS)
import AppKit
#endif

extension MediaListView {
    func item(in selection: Set<UUID>) -> MediaItem? {
        guard let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    func showInfoForSelectedItem() {
        guard isBulkEditMode == false else { return }
        guard let selectedItem else { return }
        browsingState.infoItem = selectedItem
    }

    func playSelection(_ selection: Set<UUID>) {
        guard let item = item(in: selection) else { return }
        play(item)
    }

    func play(_ item: MediaItem) {
        guard isBulkEditMode == false else { return }
        selectedItemID = item.id
        let playbackQueue = browsingState.playbackQueue(from: queue)
        browsingState.playingListName = browsingState.group?.name ?? activePlaylist?.name
            ?? section?.title ?? L10n.string("Search")
        player.play(item: item, in: playbackQueue)
    }

    func toggleBulkSelection(for item: MediaItem) {
        bulkSelection.toggle(item.id)
    }

    var bulkSelectionColor: Color {
        #if os(macOS)
        Color(nsColor: .selectedContentBackgroundColor)
        #else
        Color.accentColor
        #endif
    }

    func syncSelectionToCurrentItem() {
        guard isBulkEditMode == false else { return }
        guard let item = player.currentItem, items.contains(where: { $0.id == item.id }),
              browsingState.group?.contains(item) != false else {
            selectedItemID = nil
            return
        }
        selectedItemID = item.id
    }

    func groupTitle(for item: MediaItem) -> String {
        guard let section else { return "" }
        return switch section {
        case .albums:
            normalizedMetadata(item.displayAlbum, fallback: L10n.string("Unknown Album"))
        case .artists:
            normalizedMetadata(item.displayArtist, fallback: L10n.string("Unknown Artist"))
        case .genres:
            normalizedMetadata(item.displayGenre, fallback: L10n.string("No Genre"))
        case .allSongs, .allVideos:
            ""
        }
    }

    func secondaryText(for item: MediaItem) -> String {
        guard let section else { return item.artist }
        return switch section {
        case .albums:
            item.displayArtist
        case .artists:
            item.displayAlbum
        case .genres:
            "\(item.displayArtist) - \(item.displayAlbum)"
        case .allSongs, .allVideos:
            item.displayArtist
        }
    }

    func normalizedMetadata(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    func metadataText(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "-" : trimmed
    }

    func canMove(_ item: MediaItem, by offset: Int) -> Bool {
        guard let playlist = activePlaylist,
              let index = playlist.orderedItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }
        return playlist.orderedItems.indices.contains(index + offset)
    }

    func toggleSort(_ field: LibrarySortField) {
        guard activePlaylist == nil else { return }
        if librarySortField == field {
            librarySortDirection = librarySortDirection == .ascending ? .descending : .ascending
        } else {
            librarySortField = field
            librarySortDirection = .ascending
        }
    }
}

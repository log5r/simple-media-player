#if os(iOS)
import SwiftData
import SwiftUI

enum CompactLibraryCommandDestination: Equatable {
    case libraryRoot
    case playlistRoot
    case library(LibraryBrowsingRoute)
    case playlist(UUID)
    case videos
    case search

    @MainActor static func current(in state: LibraryBrowsingState) -> Self {
        switch state.phoneTab {
        case 0: state.libraryPath.last.map(Self.library) ?? .libraryRoot
        case 1: state.playlistPath.last.map(Self.playlist) ?? .playlistRoot
        case 2: .videos
        default: .search
        }
    }

    var isRoot: Bool {
        self == .libraryRoot || self == .playlistRoot
    }
}

/// Only the displayed destination exports scene values; retained tab views export nothing.
/// A separate carrier keeps the navigation and projection identities stable as routes change.
struct CompactLibraryCommandValues: View {
    let actions: AppMenuActions
    var info: MediaInfoCommandAction?
    var aac: AACVersionCommandAction?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .focusedSceneValue(\.appMenuActions, actions)
            .focusedSceneValue(\.mediaInfoCommandAction, info)
            .focusedSceneValue(\.aacVersionCommandAction, aac)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
struct CompactLibraryCommandContext {
    let destination: CompactLibraryCommandDestination
    let browsingState: LibraryBrowsingState
    let player: PlayerViewModel
    let actions: IPhoneLibraryActions
    let canEditLibrary: Bool
    let supportsMultipleEdit: Bool
    var playlist: Playlist?
    let queue: () -> [MediaItem]
    let selectedItem: () -> MediaItem?
    let playItem: (MediaItem) -> Void
    let showsDeck: Binding<Bool>

    var appMenuActions: AppMenuActions {
        let hasItems = queue().isEmpty == false
        let hasSelection = selectedItem() != nil
        let canPresent = showsDeck.wrappedValue == false && browsingState.showsVideoFullScreen == false
        return AppMenuActions(
            showSettings: action(isEnabled: canPresent) { browsingState.showsSettings = true },
            exportToFinder: action(isEnabled: hasItems && canEditLibrary && canPresent) {
                actions.exportItems(queue())
            },
            saveAdjustedCopy: action(isEnabled: adjustmentTarget?.isVideo == false
                && player.isVideoMode == false && player.hasPitchOrRateAdjustment && canPresent) {
                if let item = adjustmentTarget { actions.requestSaveCopy(item) }
            },
            createPlaylist: action(isEnabled: canPresent) { _ = actions.createPlaylist() },
            addTracksToPlaylist: action(isEnabled: playlist != nil && canEditLibrary && canPresent) {
                if let playlist, playlist.isDeleted == false { actions.showAddTracks(playlist) }
            },
            beginMultipleEdit: action(isEnabled: supportsMultipleEdit && hasItems && canEditLibrary
                && browsingState.isBulkEditMode == false && canPresent) {
                browsingState.bulkSelection.reset()
                browsingState.isBulkEditMode = true
            },
            editSelectedMedia: action(isEnabled: supportsMultipleEdit && browsingState.isBulkEditMode
                && selectedBulkItems.isEmpty == false && canEditLibrary && canPresent) {
                let items = selectedBulkItems
                guard items.isEmpty == false else { return }
                browsingState.bulkEditSession = BulkMetadataEditSession(items: items)
                browsingState.isBulkEditMode = false
            },
            cancelMultipleEdit: action(isEnabled: browsingState.isBulkEditMode && canPresent) {
                browsingState.endEditing()
            },
            toggleLyrics: action(isEnabled: player.currentItem?.isVideo != true && canPresent) {
                browsingState.showsDetails.toggle()
            },
            toggleEqualizer: action(isEnabled: browsingState.isBulkEditMode == false && canPresent) {
                browsingState.showsEqualizer.toggle()
            },
            toggleVideoArea: action(isEnabled: player.currentItem?.isVideo == true, requiresLibrary: false) {
                if showsDeck.wrappedValue || browsingState.showsVideoFullScreen {
                    browsingState.showsVideoFullScreen = false
                    showsDeck.wrappedValue = false
                    player.showVideoArea = false
                } else {
                    player.showVideoArea = true
                    showsDeck.wrappedValue = true
                }
            },
            playPause: action(isEnabled: player.currentItem != nil || hasSelection,
                              requiresLibrary: false) { playOrPause() },
            previousTrack: action(isEnabled: canSkip(offset: -1), requiresLibrary: false) { skip(offset: -1) },
            nextTrack: action(isEnabled: canSkip(offset: 1), requiresLibrary: false) { skip(offset: 1) },
            lyricsAreVisible: browsingState.showsDetails,
            equalizerIsVisible: browsingState.showsEqualizer,
            videoAreaIsVisible: player.isVideoMode && (showsDeck.wrappedValue || browsingState.showsVideoFullScreen)
        )
    }

    private var adjustmentTarget: MediaItem? {
        let target = player.currentItem ?? selectedItem()
        return target?.isInLibrary == true ? target : nil
    }

    private var selectedBulkItems: [MediaItem] {
        queue().filter { $0.isDeleted == false && browsingState.bulkSelection.contains($0.id) }
    }

    private func action(
        isEnabled: Bool = true, requiresLibrary: Bool = true, perform: @escaping @MainActor () -> Void
    ) -> AppMenuAction {
        AppMenuAction(isEnabled: isEnabled) {
            guard destination == .current(in: browsingState) else { return }
            if requiresLibrary && (showsDeck.wrappedValue || browsingState.showsVideoFullScreen) { return }
            perform()
        }
    }

    private func playOrPause() {
        if player.canPause {
            player.pause()
        } else if let item = selectedItem(), player.currentItem?.id != item.id {
            playItem(item)
        } else {
            player.resume()
        }
    }

    private func canSkip(offset: Int) -> Bool {
        if player.currentItem != nil {
            return offset < 0 ? player.canPlayPrevious : player.canSkipToNext
        }
        return adjacentItem(offset: offset) != nil
    }

    private func skip(offset: Int) {
        if player.currentItem != nil {
            if offset < 0 { player.previous() } else { player.next() }
        } else if let item = adjacentItem(offset: offset) {
            playItem(item)
        }
    }

    private func adjacentItem(offset: Int) -> MediaItem? {
        let items = queue()
        guard let selectedItem = selectedItem(), let index = items.firstIndex(where: { $0.id == selectedItem.id }),
              items.indices.contains(index + offset) else { return nil }
        let item = items[index + offset]
        return item.isDeleted == false ? item : nil
    }
}
#endif

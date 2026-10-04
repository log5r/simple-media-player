#if os(iOS)
import SwiftData
import SwiftUI

extension IPhoneLibraryView {
    var compactCommandDestination: CompactLibraryCommandDestination {
        .current(in: browsingState)
    }

    var compactRootCommands: CompactLibraryCommandContext {
        CompactLibraryCommandContext(
            destination: compactCommandDestination, browsingState: browsingState, player: player, actions: actions,
            canEditLibrary: canCreateAACVersion, supportsMultipleEdit: false,
            queue: { compactCommandDestination == .libraryRoot ? items : [] }, selectedItem: { nil },
            playItem: { _ in }, showsDeck: $showsDeck
        )
    }
}

extension IPhoneTrackListView {
    var compactCommandDestination: CompactLibraryCommandDestination {
        if let playlist { return .playlist(playlist.id) }
        if section == .allVideos { return .videos }
        if let group { return .library(.group(group)) }
        if let section { return .library(.section(section)) }
        return .search
    }

    var isCompactCommandDestination: Bool {
        compactCommandDestination == .current(in: browsingState)
    }

    var compactCommands: CompactLibraryCommandContext {
        CompactLibraryCommandContext(
            destination: compactCommandDestination, browsingState: browsingState, player: player, actions: actions,
            canEditLibrary: canCreateAACVersion, supportsMultipleEdit: isCategoryBrowser == false, playlist: playlist,
            queue: { orderedItems }, selectedItem: { selectedCommandItem },
            playItem: playCommandItem, showsDeck: $showsDeck
        )
    }

    var selectedCommandItem: MediaItem? {
        guard isCompactCommandDestination, isCategoryBrowser == false,
              let id = browsingState.selectedItemID,
              let item = listProjection.selectedItem(id: id), group?.contains(item) != false else { return nil }
        return item
    }

    var selectedInfoCommandAction: MediaInfoCommandAction? {
        guard browsingState.isBulkEditMode == false, showsDeck == false,
              browsingState.showsVideoFullScreen == false,
              selectedCommandItem != nil else { return nil }
        return MediaInfoCommandAction {
            guard browsingState.isBulkEditMode == false, showsDeck == false,
                  browsingState.showsVideoFullScreen == false,
                  let item = selectedCommandItem else { return }
            browsingState.infoItem = item
        }
    }

    var selectedAACVersionCommandAction: AACVersionCommandAction? {
        guard browsingState.isBulkEditMode == false, showsDeck == false, canCreateAACVersion,
              browsingState.showsVideoFullScreen == false,
              selectedCommandItem?.isVideo == false else { return nil }
        return AACVersionCommandAction {
            guard browsingState.isBulkEditMode == false, showsDeck == false, canCreateAACVersion,
                  browsingState.showsVideoFullScreen == false,
                  let item = selectedCommandItem, item.isVideo == false else { return }
            actions.createAACVersion(item)
        }
    }

    func playCommandItem(_ item: MediaItem) {
        guard isCompactCommandDestination, listProjection.selectedItem(id: item.id) != nil,
              item.isDeleted == false, group?.contains(item) != false else { return }
        play(item, orderedItems, title)
    }
}
#endif

import SwiftUI
import UniformTypeIdentifiers

extension MainView {
    /// `keepsFoldedPortraitVisible` lets iOS sheets open below the fold of the Duo portrait player.
    func withLibraryPresentations<Content: View>(
        _ content: Content, keepsFoldedPortraitVisible: Bool
    ) -> some View {
        withPlatformPresentations(content, keepsFoldedPortraitVisible: keepsFoldedPortraitVisible)
        .sheet(item: $addToPlaylistTarget) { playlist in
            PlaylistAddItemsView(playlist: playlist, items: items) { selectedItems in
                add(selectedItems, to: playlist)
            }
        }
        .sheet(item: $saveCopyTarget) { item in
            SaveTransformedCopyView(
                item: item,
                player: player,
                libraryService: libraryService,
                modelContext: modelContext,
                onComplete: { _ in
                    saveCopyTarget = nil
                },
                onCancel: {
                    saveCopyTarget = nil
                }
            )
        }
    }

    /// The Music library picker and the phone deck exist only on iPhone and iPad.
    private func withPlatformPresentations<Content: View>(
        _ content: Content, keepsFoldedPortraitVisible: Bool
    ) -> some View {
        #if os(iOS)
        withMusicLibraryPresentations(withExportPresentations(withImportPresentations(content)))
        .modifier(IOSLibraryPresentations(
            browsingState: browsingState, player: player, libraryService: libraryService,
            keepsFoldedPortraitVisible: keepsFoldedPortraitVisible,
            renamePlaylist: renamePlaylist, deletePlaylist: deletePlaylist, deleteItem: deleteLibraryItem
        ))
        .fullScreenCover(isPresented: $isPhoneDeckPresented) {
            IPhoneDeckView(
                player: player, libraryService: libraryService, listName: browsingState.playingListName,
                canCreateAACVersion: canCreateAACVersion, createAACVersion: createAACVersion,
                isPresented: $isPhoneDeckPresented, aacResultMessage: $aacVersionResultMessage,
                showsAACResult: $aacVersionResultPresented,
                showExpandedLibrary: {
                    showsPortraitLibrary = true
                    isPhoneDeckPresented = false
                }
            )
        }
        #else
        withExportPresentations(withImportPresentations(content))
        #endif
    }
}

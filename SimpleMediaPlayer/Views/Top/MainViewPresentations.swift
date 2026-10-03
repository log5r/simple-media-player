import SwiftUI
import UniformTypeIdentifiers

extension MainView {
    func withLibraryPresentations<Content: View>(_ content: Content) -> some View {
        withExportPresentations(withImportPresentations(content))
        #if os(iOS)
        .modifier(IOSLibraryPresentations(
            browsingState: browsingState, player: player, libraryService: libraryService,
            renamePlaylist: renamePlaylist, deletePlaylist: deletePlaylist, deleteItem: deleteLibraryItem
        ))
        .fullScreenCover(isPresented: $isPhoneDeckPresented) {
            IPhoneDeckView(
                player: player, libraryService: libraryService, listName: browsingState.playingListName,
                canCreateAACVersion: canCreateAACVersion, createAACVersion: createAACVersion,
                isPresented: $isPhoneDeckPresented, aacResultMessage: $aacVersionResultMessage,
                showsAACResult: $aacVersionResultPresented
            )
        }
        #endif
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
}

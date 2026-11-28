import SwiftUI
import UniformTypeIdentifiers

extension MainView {
    #if os(iOS)
    var phoneDeckPresentation: Binding<Bool> {
        guard reduceMotion else { return $isPhoneDeckPresented }
        // The default full-screen cover slides even when Reduce Motion is on.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return $isPhoneDeckPresented.transaction(transaction)
    }

    var deckEqualizerCommandContext: PhoneDeckEqualizerCommandContext {
        PhoneDeckEqualizerCommandContext(browsingState: browsingState, showsDeck: $isPhoneDeckPresented)
    }
    #endif

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
        // A later deck must not reopen the equalizer sheet left open when this one closed.
        .fullScreenCover(isPresented: phoneDeckPresentation, onDismiss: {
            browsingState.showsDeckEqualizer = false
        }, content: {
            IPhoneDeckView(
                player: player, libraryService: libraryService, listName: browsingState.playingListName,
                canCreateAACVersion: canCreateAACVersion, createAACVersion: createAACVersion,
                isPresented: phoneDeckPresentation, aacResultMessage: $aacVersionResultMessage,
                showsAACResult: $aacVersionResultPresented, showsEqualizer: $browsingState.showsDeckEqualizer,
                showExpandedLibrary: {
                    showsPortraitLibrary = true
                    phoneDeckPresentation.wrappedValue = false
                }
            )
        })
        #else
        withExportPresentations(withImportPresentations(content))
        #endif
    }
}

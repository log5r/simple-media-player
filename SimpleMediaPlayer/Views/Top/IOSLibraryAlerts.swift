#if os(iOS)
import SwiftUI

struct IOSLibraryAlerts: ViewModifier {
    @Bindable var browsingState: LibraryBrowsingState
    let renamePlaylist: (Playlist, String) -> Void
    let deletePlaylist: (Playlist) -> Void
    let deleteItem: (MediaItem) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Rename Playlist", isPresented: Binding(
                get: { browsingState.playlistToRename != nil },
                set: { if !$0 { browsingState.playlistToRename = nil } }
            )) {
                TextField("Name", text: $browsingState.nameDraft)
                Button("Rename") {
                    if let playlist = browsingState.playlistToRename {
                        renamePlaylist(playlist, browsingState.nameDraft)
                    }
                    browsingState.playlistToRename = nil
                }
                Button("Cancel", role: .cancel) { browsingState.playlistToRename = nil }
            }
            .alert("Delete Playlist?", isPresented: Binding(
                get: { browsingState.playlistToDelete != nil },
                set: { if !$0 { browsingState.playlistToDelete = nil } }
            ), presenting: browsingState.playlistToDelete) { playlist in
                Button("Delete", role: .destructive) {
                    browsingState.removePlaylist(playlist.id)
                    deletePlaylist(playlist)
                    browsingState.playlistToDelete = nil
                }
                Button("Cancel", role: .cancel) { browsingState.playlistToDelete = nil }
            } message: { playlist in
                Text(L10n.format("Delete “%@”? Media files in your library will not be deleted.", playlist.name))
            }
            .alert("Delete from Library?", isPresented: Binding(
                get: { browsingState.deleteConfirmationItem != nil },
                set: { if !$0 { browsingState.deleteConfirmationItem = nil } }
            ), presenting: browsingState.deleteConfirmationItem) { item in
                Button("Delete", role: .destructive) {
                    deleteItem(item)
                    browsingState.deleteConfirmationItem = nil
                }
                Button("Cancel", role: .cancel) { browsingState.deleteConfirmationItem = nil }
            } message: { item in
                Text(L10n.format("Delete “%@” from your library. This action cannot be undone.", item.title))
            }
    }
}
#endif

#if os(iOS)
import SwiftUI

struct IOSLibraryPresentations: ViewModifier {
    @Bindable var browsingState: LibraryBrowsingState
    let player: PlayerViewModel
    let libraryService: LibraryService
    /// On a partially folded Duo in portrait, the player's sheets start below the fold so the LED stays visible.
    let keepsFoldedPortraitVisible: Bool
    let renamePlaylist: (Playlist, String) -> Void
    let deletePlaylist: (Playlist) -> Void
    let deleteItem: (MediaItem) -> Void

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $browsingState.showsVideoFullScreen) {
                FullScreenVideoView(player: player)
            }
            .onChange(of: player.currentItem?.isVideo) { _, isVideo in
                if isVideo != true { browsingState.showsVideoFullScreen = false }
            }
            .sheet(isPresented: $browsingState.showsSettings) {
                AppSettingsView(player: player).presentationDetents(playerSheetDetents)
            }
            .sheet(isPresented: $browsingState.showsFilters) {
                AdvancedSearchView(filter: $browsingState.searchFilter)
            }
            .sheet(isPresented: $browsingState.showsDetails) {
                LyricsPanelView(
                    item: player.currentItem,
                    listIndex: player.queue.firstIndex { $0.id == player.currentItem?.id }.map { $0 + 1 },
                    libraryService: libraryService,
                    contentSelection: $browsingState.panelContent
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("libraryDetailsSheet")
                .presentationDetents(playerSheetDetents)
            }
            .sheet(isPresented: $browsingState.showsEqualizer) {
                equalizerSheet.presentationDetents(playerSheetDetents)
            }
            .sheet(item: $browsingState.lyricsItem) { item in
                LyricsEditorView(item: item, libraryService: libraryService)
            }
            .sheet(item: $browsingState.infoItem) { item in
                MediaInfoView(item: item, libraryService: libraryService)
            }
            .sheet(item: $browsingState.artworkPreview) { preview in
                LibraryArtworkPreviewView(preview: preview)
            }
            .sheet(item: $browsingState.bulkEditSession, onDismiss: {
                browsingState.bulkSelection.reset()
            }, content: { session in
                BulkMetadataEditView(items: session.items, libraryService: libraryService)
            })
            .modifier(IOSLibraryAlerts(
                browsingState: browsingState, renamePlaylist: renamePlaylist,
                deletePlaylist: deletePlaylist, deleteItem: deleteItem
            ))
    }

    /// `.large` alone matches the default, so the sheet keeps its content when the fold changes.
    private var playerSheetDetents: Set<PresentationDetent> {
        keepsFoldedPortraitVisible ? [.medium, .large] : [.large]
    }

    private var equalizerSheet: some View {
        NavigationStack {
            ScrollView { EqualizerPanelView(player: player) }
                .navigationTitle("Equalizer")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { browsingState.showsEqualizer = false }
                    }
                }
                .disablesVerticalToolbar()
        }
    }
}
#endif

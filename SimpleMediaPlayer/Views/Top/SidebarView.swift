import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection
    let playlists: [Playlist]
    let createPlaylist: () -> Void
    let renamePlaylist: (Playlist, String) -> Void
    let deletePlaylist: (Playlist) -> Void
    @Bindable var browsingState: LibraryBrowsingState

    var body: some View {
        sidebarList
            .listStyle(.sidebar)
            .accessibilityIdentifier("librarySidebar")
            .navigationTitle("Library")
            #if os(macOS)
            .alert(
                "Rename Playlist",
                isPresented: Binding(
                    get: { browsingState.playlistToRename != nil },
                    set: { if $0 == false { browsingState.playlistToRename = nil } }
                )
            ) {
                TextField("Name", text: $browsingState.nameDraft)
                Button("Rename") {
                    if let playlistToRename = browsingState.playlistToRename {
                        renamePlaylist(playlistToRename, browsingState.nameDraft)
                    }
                    browsingState.playlistToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    browsingState.playlistToRename = nil
                }
            }
            .alert(
                "Delete Playlist?",
                isPresented: Binding(
                    get: { browsingState.playlistToDelete != nil },
                    set: { if $0 == false { browsingState.playlistToDelete = nil } }
                ),
                presenting: browsingState.playlistToDelete
            ) { playlist in
                Button("Delete", role: .destructive) {
                    deletePlaylist(playlist)
                    browsingState.removePlaylist(playlist.id)
                    browsingState.playlistToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    browsingState.playlistToDelete = nil
                }
            } message: { playlist in
                Text(L10n.format("Delete “%@”? Media files in your library will not be deleted.", playlist.name))
            }
            #endif
    }

    @ViewBuilder
    private var sidebarList: some View {
        #if os(macOS)
        List(selection: $selection) {
            sidebarContent
        }
        .modifier(FocusOnTapModifier())
        #else
        List {
            sidebarContent
        }
        #endif
    }

    @ViewBuilder
    private var sidebarContent: some View {
        Section("Library") {
            ForEach(LibrarySection.allCases) { section in
                libraryRow(section)
            }
        }

        Section("Playlists") {
            ForEach(playlists) { playlist in
                playlistRow(playlist)
            }

            Button {
                createPlaylist()
            } label: {
                Label("Add Playlist", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("New Playlist")
            .accessibilityIdentifier("addPlaylistButton")
        }
    }

    private func libraryRow(_ section: LibrarySection) -> some View {
        Label(section.title, systemImage: section.icon)
            .tag(SidebarSelection.library(section))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebarLibraryRow.\(section.rawValue)")
            .onTapGesture {
                selection = .library(section)
                browsingState.select(.library(section))
            }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        Label(playlist.name, systemImage: "music.note.list")
            .lineLimit(1)
            .tag(SidebarSelection.playlist(playlist.id))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebarPlaylistRow.\(playlist.id.uuidString)")
            .onTapGesture {
                selection = .playlist(playlist.id)
                browsingState.select(.playlist(playlist.id))
            }
            .contextMenu {
                playlistMenu(for: playlist)
            }
    }

    @ViewBuilder
    private func playlistMenu(for playlist: Playlist) -> some View {
        Button {
            beginRename(playlist)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button(role: .destructive) {
            browsingState.playlistToDelete = playlist
        } label: {
            Label("Delete Playlist", systemImage: "trash")
        }
    }

    private func beginRename(_ playlist: Playlist) {
        browsingState.nameDraft = playlist.name
        browsingState.playlistToRename = playlist
    }
}

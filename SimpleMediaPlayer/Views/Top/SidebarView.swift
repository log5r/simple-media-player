import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection
    let playlists: [Playlist]
    let createPlaylist: () -> Void
    let renamePlaylist: (Playlist, String) -> Void
    let deletePlaylist: (Playlist) -> Void

    @State private var playlistToRename: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var nameDraft = ""

    var body: some View {
        sidebarList
            .listStyle(.sidebar)
            .navigationTitle("Library")
            .alert(
                "Rename Playlist",
                isPresented: Binding(
                    get: { playlistToRename != nil }, set: { if $0 == false { playlistToRename = nil } }
                )
            ) {
                TextField("Name", text: $nameDraft)
                Button("Rename") {
                    if let playlistToRename {
                        renamePlaylist(playlistToRename, nameDraft)
                    }
                    playlistToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    playlistToRename = nil
                }
            }
            .alert(
                "Delete Playlist?",
                isPresented: Binding(
                    get: { playlistToDelete != nil }, set: { if $0 == false { playlistToDelete = nil } }
                ),
                presenting: playlistToDelete
            ) { playlist in
                Button("Delete", role: .destructive) {
                    deletePlaylist(playlist)
                    playlistToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    playlistToDelete = nil
                }
            } message: { playlist in
                Text(L10n.format("Delete “%@”? Media files in your library will not be deleted.", playlist.name))
            }
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
            .accessibilityIdentifier("sidebarLibraryRow.\(section.rawValue)")
            .onTapGesture {
                selection = .library(section)
            }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        Label(playlist.name, systemImage: "music.note.list")
            .lineLimit(1)
            .tag(SidebarSelection.playlist(playlist.id))
            .accessibilityIdentifier("sidebarPlaylistRow.\(playlist.id.uuidString)")
            .onTapGesture {
                selection = .playlist(playlist.id)
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
            playlistToDelete = playlist
        } label: {
            Label("Delete Playlist", systemImage: "trash")
        }
    }

    private func beginRename(_ playlist: Playlist) {
        nameDraft = playlist.name
        playlistToRename = playlist
    }
}

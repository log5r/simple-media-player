import SwiftUI

extension MediaListView {
    func groupedRow(_ row: MediaTableRow) -> some View {
        let isBulkSelected = isBulkEditMode && bulkSelection.contains(row.id)
        return groupedRowContent(row, isBulkSelected: isBulkSelected)
            .contentShape(Rectangle())
            .foregroundStyle(isBulkSelected ? Color.white : Color.primary)
            .background(isBulkSelected ? bulkSelectionColor : Color.clear)
            .contextMenu {
                if isBulkEditMode == false { rowMenu(for: row.item) }
            }
            .onTapGesture { selectGroupedRow(row) }
            #if os(macOS)
            .onTapGesture(count: 2) {
                if isBulkEditMode == false { play(row.item) }
            }
            #endif
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isBulkSelected ? .isSelected : [])
            .accessibilityAction { selectGroupedRow(row) }
    }

    func groupedRowContent(_ row: MediaTableRow, isBulkSelected: Bool) -> some View {
        HStack(spacing: 10) {
            if differentiateWithoutColor, isBulkSelected {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityHidden(true)
            }
            Text("\(row.index)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            LibraryItemArtworkView(item: row.item)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if player.currentItem?.id == row.id {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.secondary)
                    }
                    Text(row.item.title)
                        .lineLimit(1)
                }

                Text(secondaryText(for: row.item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(row.item.duration.mediaTime)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    func selectGroupedRow(_ row: MediaTableRow) {
        if isBulkEditMode {
            toggleBulkSelection(for: row.item)
        } else {
            #if os(iOS)
            play(row.item)
            #else
            selectedItemID = row.id
            #endif
        }
    }

    @ViewBuilder
    func rowMenu(for item: MediaItem) -> some View {
        Button {
            browsingState.infoItem = item
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }

        Divider()

        Button {
            createAACVersion(item)
        } label: {
            Label("Create AAC Version", systemImage: "waveform.badge.plus")
        }
        .disabled(item.isVideo || canCreateAACVersion == false)

        Divider()

        if activePlaylist != nil { playlistRowMenu(for: item) }

        addToPlaylistMenu(for: item)

        Divider()

        Button(role: .destructive) {
            browsingState.deleteConfirmationItem = item
        } label: {
            Label("Delete from Library", systemImage: "trash")
        }
    }

    @ViewBuilder
    func playlistRowMenu(for item: MediaItem) -> some View {
        Button {
            movePlaylistItem(item, -1)
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(canMove(item, by: -1) == false)

        Button {
            movePlaylistItem(item, 1)
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(canMove(item, by: 1) == false)

        Button {
            removeFromPlaylist(item)
        } label: {
            Label("Remove from Playlist", systemImage: "minus.circle")
        }

        Divider()
    }

    func addToPlaylistMenu(for item: MediaItem) -> some View {
        Menu {
            Button {
                createPlaylistWithItem(item)
            } label: {
                Label("New Playlist", systemImage: "plus")
            }

            if playlists.isEmpty == false {
                Divider()
            }

            ForEach(playlists) { playlist in
                Button {
                    addToPlaylist(item, playlist)
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
                .disabled(playlist.contains(item))
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

    }

}

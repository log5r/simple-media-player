import SwiftUI

struct PlaylistAddItemsView: View {
    let playlist: Playlist
    let items: [MediaItem]
    let addItems: ([MediaItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText = ""

    var body: some View {
        // Evaluate the filter once per body pass; both the empty check and the list read the result.
        let candidates = PlaylistAddCandidateFilter.candidates(
            from: items,
            excluding: Set(playlist.entries.compactMap { $0.item?.id }),
            searchText: searchText
        )
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No Media to Add",
                        systemImage: "music.note.list",
                        description: Text("Items already in this playlist are hidden.")
                    )
                } else {
                    List(candidates) { item in
                        Button {
                            toggle(item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        selectedIDs.contains(item.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                                    )

                                Image(systemName: item.isVideo ? "film" : "music.note")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .lineLimit(1)
                                    Text("\(item.displayArtist) - \(item.displayAlbum)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text(item.duration.mediaTime)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedIDs.contains(item.id) ? .isSelected : [])
                        .accessibilityValue(selectedIDs.contains(item.id) ? Text("Selected") : Text("Not Selected"))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add Tracks")
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addItems(items.filter { selectedIDs.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private func toggle(_ item: MediaItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }
}

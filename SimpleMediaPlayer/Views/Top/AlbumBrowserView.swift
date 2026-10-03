import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct AlbumBrowserView<ItemMenu: View>: View {
    let items: [MediaItem]
    let player: PlayerViewModel
    @Binding var selectedItemID: UUID?
    @Binding var isBulkEditMode: Bool
    let bulkSelection: BulkMediaSelectionState
    @Bindable var browsingState: LibraryBrowsingState
    let itemMenu: (MediaItem) -> ItemMenu

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var artworkTransition

    private var selectedAlbumID: String? {
        get { browsingState.group?.section == .albums ? browsingState.group?.name : nil }
        nonmutating set {
            if let newValue {
                browsingState.openGroup(section: .albums, name: newValue)
            } else {
                browsingState.closeGroup()
            }
        }
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20, alignment: .top)
    ]

    var body: some View {
        Group {
            if let selectedAlbum {
                albumDetail(selectedAlbum)
            } else {
                albumGrid
            }
        }
        .onChange(of: albums.map(\.id)) { _, albumIDs in
            if let selectedAlbumID, albumIDs.contains(selectedAlbumID) == false {
                self.selectedAlbumID = nil
            }
        }
    }

    private var albums: [LibraryAlbum] {
        LibraryAlbum.grouped(items)
    }

    private var selectedAlbum: LibraryAlbum? {
        guard let selectedAlbumID else { return nil }
        return albums.first { $0.id == selectedAlbumID }
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 24) {
                ForEach(albums) { album in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                            selectedAlbumID = album.id
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            AlbumArtworkView(artworkID: album.artworkID)
                                .matchedGeometryEffect(id: album.id, in: artworkTransition)

                            Text(album.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            Text(album.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(album.title), \(album.artist)")
                    .accessibilityIdentifier("libraryGroup.albums.\(album.id)")
                    .id(album.id)
                }
            }
            .scrollTargetLayout()
            .padding(24)
        }
        .scrollPosition(id: $browsingState.albumScrollID, anchor: .top)
        .background(.background)
    }

    private func albumDetail(_ album: LibraryAlbum) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                        selectedAlbumID = nil
                    }
                } label: {
                    Label("Back to List", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("libraryGroupBackButton")
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

                albumHeader(album)
                    .padding(.bottom, 24)

                Divider()

                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { offset, item in
                    albumTrackRow(item, fallbackNumber: offset + 1, tracks: album.tracks)
                        .id(item.id)
                        .modifier(LibraryScrollAnchorRow(id: item.id))

                    if offset < album.tracks.count - 1 {
                        Divider()
                            .padding(.leading, 50)
                    }
                }
            }
            .padding(24)
        }
        .modifier(LibraryScrollAnchor(itemIDs: album.tracks.map(\.id), browsingState: browsingState))
        .background(.background)
    }

    @ViewBuilder
    private func albumHeader(_ album: LibraryAlbum) -> some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: 20) {
                albumArtwork(album)
                    .frame(maxWidth: 260)
                albumInformation(album)
            }
        } else {
            HStack(alignment: .bottom, spacing: 30) {
                albumArtwork(album)
                    .frame(width: 240, height: 240)
                albumInformation(album)
                    .padding(.bottom, 4)
                Spacer(minLength: 0)
            }
        }
    }

    private func albumArtwork(_ album: LibraryAlbum) -> some View {
        AlbumArtworkView(artworkID: album.artworkID)
            .matchedGeometryEffect(id: album.id, in: artworkTransition)
    }

    private func albumInformation(_ album: LibraryAlbum) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(album.title)
                .font(.largeTitle.bold())
                .textSelection(.enabled)

            Text(album.artist)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .textSelection(.enabled)

            if album.metadataSummary.isEmpty == false {
                Text(album.metadataSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(L10n.format("%d songs", album.tracks.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                guard let firstTrack = album.tracks.first else { return }
                play(firstTrack, in: album.tracks)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBulkEditMode)
            .padding(.top, 14)
        }
    }

    private func albumTrackRow(_ item: MediaItem, fallbackNumber: Int, tracks: [MediaItem]) -> some View {
        let isSelected = isBulkEditMode ? bulkSelection.contains(item.id) : selectedItemID == item.id

        return albumTrackContent(item, fallbackNumber: fallbackNumber)
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .clipShape(.rect(cornerRadius: 6))
        .contextMenu {
            if isBulkEditMode == false { itemMenu(item) }
        }
        .onTapGesture { selectTrack(item, tracks: tracks) }
        #if os(macOS)
        .onTapGesture(count: 2) {
            if isBulkEditMode == false { play(item, in: tracks) }
        }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("libraryTrack.\(item.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { selectTrack(item, tracks: tracks) }
    }

    private func albumTrackContent(_ item: MediaItem, fallbackNumber: Int) -> some View {
        let isSelected = isBulkEditMode ? bulkSelection.contains(item.id) : selectedItemID == item.id
        return HStack(spacing: 12) {
            if differentiateWithoutColor, isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityHidden(true)
            }
            Text(trackNumber(for: item, fallback: fallbackNumber))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)

            if player.currentItem?.id == item.id {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)

                if item.displayArtist != selectedAlbum?.artist {
                    Text(item.displayArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(item.duration.mediaTime)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func selectTrack(_ item: MediaItem, tracks: [MediaItem]) {
        if isBulkEditMode {
            bulkSelection.toggle(item.id)
        } else {
            #if os(iOS)
            play(item, in: tracks)
            #else
            selectedItemID = item.id
            #endif
        }
    }

    private func play(_ item: MediaItem, in tracks: [MediaItem]) {
        selectedItemID = item.id
        browsingState.playingListName = selectedAlbum?.title ?? item.displayAlbum
        player.play(item: item, in: tracks)
    }

    private func trackNumber(for item: MediaItem, fallback: Int) -> String {
        let value = item.trackNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty == false else { return "\(fallback)" }
        return String(value.split(separator: "/", maxSplits: 1).first ?? Substring(value))
    }
}

struct LibraryAlbum: Identifiable {
    let id: String
    let title: String
    let artist: String
    let artworkID: UUID?
    let metadataSummary: String
    let tracks: [MediaItem]

    static func grouped(_ items: [MediaItem]) -> [LibraryAlbum] {
        Dictionary(grouping: items, by: \.displayAlbum)
            .map { title, albumItems in
                let tracks = albumItems.sorted(by: trackComesBefore)
                let firstTrack = tracks[0]
                let artist = firstNonBlankAlbumArtist(in: tracks) ?? summarizedArtist(in: tracks)
                let metadataSummary = [firstTrack.year, firstTrack.genre]
                    .compactMap(normalized)
                    .joined(separator: " • ")

                return LibraryAlbum(
                    id: title,
                    title: title,
                    artist: artist,
                    artworkID: tracks.lazy.compactMap(\.artworkID).first,
                    metadataSummary: metadataSummary,
                    tracks: tracks
                )
            }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    private static func firstNonBlankAlbumArtist(in items: [MediaItem]) -> String? {
        items.lazy.compactMap { normalized($0.albumArtist) }.first
    }

    private static func summarizedArtist(in items: [MediaItem]) -> String {
        guard let firstArtist = items.first?.displayArtist else { return L10n.string("Various Artists") }
        for item in items.dropFirst() where firstArtist.localizedStandardCompare(item.displayArtist) != .orderedSame {
            return L10n.string("Various Artists")
        }
        return firstArtist
    }

    private static func trackComesBefore(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        let lhsKey = (metadataNumber(lhs.discNumber), metadataNumber(lhs.trackNumber))
        let rhsKey = (metadataNumber(rhs.discNumber), metadataNumber(rhs.trackNumber))

        if lhsKey.0 != rhsKey.0 { return lhsKey.0 < rhsKey.0 }
        if lhsKey.1 != rhsKey.1 { return lhsKey.1 < rhsKey.1 }

        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func metadataNumber(_ value: String?) -> Int {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = trimmed.prefix { $0.isNumber }
        return Int(prefix) ?? .max
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AlbumArtworkView: View {
    let artworkID: UUID?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            LibraryArtworkView(artworkID: artworkID)
                .font(.system(size: 42, weight: .light))
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }
}

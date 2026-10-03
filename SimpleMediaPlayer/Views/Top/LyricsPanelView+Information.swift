import SwiftUI
import SwiftData

extension LyricsPanelView {
    func showArtworkPreview(for item: MediaItem, data: Data) {
        #if os(macOS)
        openWindow(id: ArtworkPreviewWindow.sceneID, value: item.id)
        #else
        if let browsingState {
            browsingState.artworkPreview = LibraryArtworkPreview(itemID: item.id, data: data)
        } else {
            isArtworkPreviewPresented = true
        }
        #endif
    }

    func informationRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(usesTouchControls ? .body : .system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    func artworkInformationRow(item: MediaItem, artworkData: Data?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(MediaListColumn.artwork.settingsTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let artworkData,
               let image = platformImage(data: artworkData) {
                Button {
                    showArtworkPreview(for: item, data: artworkData)
                } label: {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Enlarge Artwork")
                .help("Enlarge Artwork")
                #if !os(macOS)
                .popover(isPresented: $isArtworkPreviewPresented) {
                    artworkPreview(image)
                }
                #endif
            } else {
                Label("No artwork available", systemImage: "photo")
                    .font(usesTouchControls ? .body : .system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    func informationValue(for column: MediaListColumn, item: MediaItem) -> String {
        switch column {
        case .index:
            listIndex.map(String.init) ?? "-"
        case .artwork:
            ""
        case .title:
            metadataText(informationDraft.map(\.title) ?? item.title, fallback: item.title)
        case .artist:
            metadataText(informationDraft.map(\.artist) ?? item.artist, fallback: item.displayArtist)
        case .album:
            metadataText(informationDraft.map(\.album) ?? item.album, fallback: item.displayAlbum)
        case .genre:
            metadataText(informationDraft.map(\.genre) ?? item.genre, fallback: item.displayGenre)
        case .duration:
            item.duration.mediaTime
        default:
            additionalInformationValue(for: column, item: item)
        }
    }

    private func additionalInformationValue(for column: MediaListColumn, item: MediaItem) -> String {
        switch column {
        case .trackNumber:
            metadataText(informationDraft.map(\.trackNumber) ?? item.trackNumber)
        case .year:
            metadataText(informationDraft.map(\.year) ?? item.year)
        case .albumArtist:
            metadataText(informationDraft.map(\.albumArtist) ?? item.albumArtist)
        case .composer:
            metadataText(informationDraft.map(\.composer) ?? item.composer)
        case .discNumber:
            metadataText(informationDraft.map(\.discNumber) ?? item.discNumber)
        case .kind:
            mediaKindText(for: item)
        case .contentType:
            item.displayContentType
        case .dateAdded:
            item.addedAt.formatted(date: .numeric, time: .omitted)
        case .fileName:
            item.fileName
        default:
            ""
        }
    }

    private func mediaKindText(for item: MediaItem) -> String {
        if item.isVideo { L10n.string("Video") } else { L10n.string("Audio") }
    }

    func metadataText(_ value: String?, fallback: String = "-") -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    func informationArtworkData(for item: MediaItem) -> Data? {
        guard informationDraftItemID == item.id,
              informationDraftArtworkID == item.artworkID else { return nil }
        return informationDraft?.artworkData
    }

    func reloadInformation() async {
        let requestID = UUID()
        informationLoadRequestID = requestID
        informationDraftItemID = nil
        informationDraftArtworkID = nil
        informationDraft = nil

        guard let item else {
            informationDraft = nil
            return
        }

        let itemID = item.id
        let artworkID = item.artworkID
        guard let draft = try? await libraryService.editableMetadataDraft(for: item) else { return }
        guard Task.isCancelled == false,
              self.item?.id == itemID,
              self.item?.artworkID == artworkID,
              informationLoadRequestID == requestID else { return }
        informationDraft = draft
        informationDraftItemID = itemID
        informationDraftArtworkID = artworkID
    }

    func platformImage(data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }

}

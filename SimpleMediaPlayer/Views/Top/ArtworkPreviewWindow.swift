#if os(macOS)
import SwiftData
import SwiftUI

struct ArtworkPreviewWindow: View {
    static let sceneID = "artwork-preview"

    @Query private var items: [MediaItem]

    init(itemID: UUID?) {
        let resolvedID = itemID ?? UUID()
        _items = Query(filter: #Predicate<MediaItem> { item in
            item.id == resolvedID
        })
    }

    var body: some View {
        Group {
            if let item,
               let artworkData = item.artworkData,
               let artwork = NSImage(data: artworkData) {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Artwork")
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No artwork available", systemImage: "photo")
            }
        }
        .frame(minWidth: 320, minHeight: 320)
        .background(.background)
        .navigationTitle(windowTitle)
    }

    private var item: MediaItem? {
        items.first
    }

    private var windowTitle: String {
        guard let item else { return L10n.string("Artwork") }
        return "\(item.displayAlbum) — \(item.title)"
    }
}
#endif

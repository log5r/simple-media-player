import CoreGraphics
import SwiftData
import SwiftUI

struct LibraryItemArtworkView: View {
    let item: MediaItem

    var body: some View {
        LibraryArtworkView(artworkID: item.artworkID, isVideo: item.isVideo, maxPixelSize: 96)
            .frame(width: 22, height: 22)
            .clipShape(.rect(cornerRadius: 3))
    }
}

struct LibraryArtworkView: View {
    let artworkID: UUID?
    var isVideo = false
    var maxPixelSize = 600
    var contentMode: ContentMode = .fill

    @Environment(\.modelContext) private var modelContext
    @State private var image: CGImage?
    @State private var loadedRequest: ArtworkRequest?
    @State private var loadRequestID: UUID?

    var body: some View {
        Group {
            if loadedRequest == request, let image {
                Image(image, scale: 1, label: Text("Artwork"))
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityIdentifier("libraryArtworkImage")
            } else {
                Image(systemName: isVideo ? "film" : "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: request) {
            await loadImage()
        }
        .onDisappear {
            loadRequestID = nil
            image = nil
            loadedRequest = nil
        }
    }

    private var request: ArtworkRequest {
        ArtworkRequest(artworkID: artworkID, maxPixelSize: maxPixelSize)
    }

    private func loadImage() async {
        let request = request
        let requestID = UUID()
        loadRequestID = requestID
        image = nil
        loadedRequest = nil
        guard let artworkID = request.artworkID else { return }

        let loadedImage = try? await LibraryArtworkLoader.shared.image(
            for: artworkID,
            in: modelContext,
            maxPixelSize: request.maxPixelSize
        )
        guard Task.isCancelled == false, loadRequestID == requestID else { return }
        image = loadedImage
        loadedRequest = request
    }
}

private struct ArtworkRequest: Equatable {
    let artworkID: UUID?
    let maxPixelSize: Int
}

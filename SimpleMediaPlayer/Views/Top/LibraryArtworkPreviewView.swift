#if os(iOS)
import SwiftUI
import UIKit

struct LibraryArtworkPreviewView: View {
    let preview: LibraryArtworkPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let image = UIImage(data: preview.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Artwork")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("artworkPreviewCloseButton")
            .padding(12)
        }
        #if DEBUG
        .modifier(DuoEditorDiagnostics(kind: "artwork", itemID: preview.itemID, draft: [:], isBusy: false))
        #endif
    }
}
#endif

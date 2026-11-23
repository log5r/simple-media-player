import SwiftData
import SwiftUI

/// Model changes and list conditions update the projection; row selection only reads its result.
struct LibraryListUpdates: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    let projection: LibraryListProjection
    let libraryService: LibraryService
    let items: [MediaItem]
    let playlist: Playlist?
    let request: LibraryListRequest

    func body(content: Content) -> some View {
        content
            .onChange(of: Source(items: items, playlist: playlist), initial: true) { _, source in
                projection.update(
                    items: source.items, playlist: source.playlist, request: request,
                    importBatch: libraryService.importBatch(for: source.items, in: modelContext)
                )
            }
            .onChange(of: request) { _, request in projection.update(request: request) }
            .onDisappear { projection.cancel() }
    }

    private nonisolated struct Source: Equatable {
        let items: [MediaItem]
        let playlist: Playlist?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.playlist === rhs.playlist && lhs.items.count == rhs.items.count
                && lhs.items.elementsEqual(rhs.items) { $0 === $1 }
        }
    }
}

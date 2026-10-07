import Foundation
import Observation

/// Retains album aggregation across selection, playback, and detail-row redraws.
@MainActor
@Observable
final class LibraryAlbumProjection {
    private(set) var albums: [LibraryAlbum] = []

    @ObservationIgnored private var source: [MediaItem]?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let lifetime = LibraryAlbumObservationLifetime()
    @ObservationIgnored private let group: @MainActor ([MediaItem]) -> [LibraryAlbum]

    init(group: @escaping @MainActor ([MediaItem]) -> [LibraryAlbum] = LibraryAlbum.grouped) {
        self.group = group
    }

    func update(items: [MediaItem]) {
        if let source, source.elementsEqual(items, by: { $0 === $1 }) { return }
        source = items
        refresh()
    }

    func clear() {
        generation &+= 1
        // Retire the one-shot metadata tracker, including when its source never changes again.
        lifetime.revision &+= 1
        source = nil
        albums = []
    }

    private func refresh() {
        guard let source else { return }
        generation &+= 1
        let currentGeneration = generation
        lifetime.revision &+= 1
        albums = withObservationTracking {
            _ = lifetime.revision
            return group(source)
        } onChange: { [weak self] in
            // Observation fires before the setter finishes. Aggregate on the next actor turn,
            // coalescing edits and ignoring callbacks for replaced or cleared sources.
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.refresh()
            }
        }
    }
}

@MainActor
@Observable
private final class LibraryAlbumObservationLifetime {
    var revision: UInt64 = 0
}

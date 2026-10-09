import Foundation
import SwiftUI

extension Playlist {
    var orderedEntries: [PlaylistEntry] {
        entries.sorted { lhs, rhs in
            if lhs.sortIndex == rhs.sortIndex {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sortIndex < rhs.sortIndex
        }
    }

    var orderedItems: [MediaItem] {
        orderedEntries.compactMap(\.item)
    }

    func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let existingEntries = orderedEntries
        // UI offsets exclude entries left behind by deleted media items.
        var itemEntries = existingEntries.filter { $0.item != nil }
        guard source.isEmpty == false,
              source.allSatisfy({ itemEntries.indices.contains($0) }),
              (0...itemEntries.count).contains(destination) else { return }
        itemEntries.move(fromOffsets: source, toOffset: destination)
        let missingEntries = existingEntries.filter { $0.item == nil }
        for (index, entry) in (itemEntries + missingEntries).enumerated() {
            entry.sortIndex = index
        }
    }

    func moveItem(_ item: MediaItem, by offset: Int) {
        let items = orderedItems
        guard offset != 0, let sourceIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        let destinationIndex = sourceIndex + offset
        guard items.indices.contains(destinationIndex) else { return }
        moveItems(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destinationIndex + (offset > 0 ? 1 : 0)
        )
    }

    func contains(_ item: MediaItem) -> Bool {
        entries.contains { $0.item?.id == item.id }
    }
}

import Foundation
import SwiftData

nonisolated struct LibraryArtworkSnapshot: Sendable {
    let data: Data?
}

extension LibraryService {
    func validateCopySource(_ item: MediaItem, in originalContext: ModelContext?) throws {
        try Task.checkCancellation()
        guard item.isDeleted == false, item.modelContext === originalContext else {
            throw CancellationError()
        }
    }

    func artworkForCopy(of item: MediaItem, snapshot: LibraryArtworkSnapshot?) async throws -> Data? {
        if let snapshot { return snapshot.data }
        return try await libraryArtwork(for: item)
    }

    func libraryArtwork(for item: MediaItem) async throws -> Data? {
        try Task.checkCancellation()
        guard let artworkID = item.artworkID else { return nil }
        guard let context = item.modelContext else {
            // A not-yet-inserted item already owns its bytes in memory.
            return item.artworkData
        }
        // Pending inserts are already in memory but invisible to the worker's saved-store context.
        if let data = LibraryArtworkStorage.pendingData(for: artworkID, in: context) {
            return data
        }
        do {
            let data = try await artworkLoader.data(for: artworkID, in: context.container)
            try validateArtworkRead(item, in: context, artworkID: artworkID)
            return data
        } catch {
            // A replaced/deleted record may fail to fetch before the worker can return its bytes.
            try validateArtworkRead(item, in: context, artworkID: artworkID)
            throw error
        }
    }

    private func validateArtworkRead(_ item: MediaItem, in context: ModelContext, artworkID: UUID) throws {
        try Task.checkCancellation()
        guard item.modelContext === context, item.isDeleted == false, item.artworkID == artworkID else {
            throw CancellationError()
        }
    }
}

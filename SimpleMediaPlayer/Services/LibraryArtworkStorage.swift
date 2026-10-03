import Foundation
import SwiftData

nonisolated enum LibraryArtworkStorage {
    @MainActor
    static func pendingData(for artworkID: UUID, in context: ModelContext) -> Data? {
        // Inspect only pending inserts; fetching a saved relationship here would fault its bytes on MainActor.
        context.insertedModelsArray.lazy.compactMap { $0 as? MediaArtwork }
            .first { $0.id == artworkID }?.data
    }

    static func migrate(in container: ModelContainer) async throws {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            while true {
                try Task.checkCancellation()
                let migrated = try autoreleasepool {
                    try migrateNextItem(in: container)
                }
                guard migrated else { return }
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func migrateNextItem(in container: ModelContainer) throws -> Bool {
        // A context per item releases registered models and their old inline image bytes.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.legacyArtworkData != nil })
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = false
        guard let item = try context.fetch(descriptor).first,
              let data = item.legacyArtworkData else { return false }
        try Task.checkCancellation()
        item.artworkData = data
        // Creation and clearing the legacy column commit together, so interruption can resume.
        try context.save()
        return true
    }
}

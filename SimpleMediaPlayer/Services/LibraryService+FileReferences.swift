import Foundation
import SwiftData

/// Paths that resolve bookmarks or touch library files for many items at once. The main actor only captures
/// value snapshots; resolution and file system access run in workers.
extension LibraryService {
    func fileReference(for item: MediaItem) -> MediaFileReference {
        MediaFileReference(id: item.id, bookmarkData: item.bookmarkData, fileName: item.fileName)
    }

    /// Resolving a bookmark touches the file system, so bulk and UI paths call this from a worker.
    nonisolated func resolvedURL(for reference: MediaFileReference) -> URL {
        resolveBookmark(reference.bookmarkData, fallbackMediaURL(forFileName: reference.fileName))
    }

    /// Removes the item immediately and its file in the returned background task. The journal entry written
    /// before the item is deleted lets the next launch finish a removal that termination interrupted.
    @discardableResult
    func delete(_ item: MediaItem, from context: ModelContext) -> Task<Void, Never>? {
        let itemID = item.id
        guard deletedItemIDs.contains(itemID) == false else { return nil }
        let linkedEntries = FetchDescriptor<PlaylistEntry>(predicate: #Predicate { $0.item?.id == itemID })
        guard let entries = try? context.fetch(linkedEntries) else { return nil }
        // The unidirectional item relationship has no inverse to nullify on deletion.
        for entry in entries { entry.item = nil }
        let removal = PendingFileRemovalJournal.Entry(
            id: itemID,
            bookmarkData: item.bookmarkData,
            fallbackPath: fallbackMediaURL(forFileName: item.fileName).path
        )
        deletedItemIDs.insert(itemID)
        removalJournal.add(removal)
        context.delete(item)
        try? context.save()
        // Managed file names are unique per item, so a late removal cannot reach a newer import.
        return Task.detached(priority: .utility) { [self] in removeFile(for: removal) }
    }

    /// Finishes removals recorded by earlier launches; call once when the app starts.
    @discardableResult
    func resumePendingFileRemovals() -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            for removal in removalJournal.entries(in: mediaDirectoryURL()) {
                removeFile(for: removal)
            }
        }
    }

    private nonisolated func removeFile(for removal: PendingFileRemovalJournal.Entry) {
        let url = resolveBookmark(removal.bookmarkData, URL(fileURLWithPath: removal.fallbackPath))
        if let cacheURL = ExtendedAudioSource.cacheURL(for: url) {
            ExtendedAudioSource.removeCacheInBackground(at: cacheURL)
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Keep the entry so the next launch retries; a file that is already gone needs no retry.
            guard FileManager.default.fileExists(atPath: url.path) == false else { return }
        }
        removalJournal.remove(id: removal.id)
    }

    /// Checked after every awaited probe: a deleted item's file can outlive the item until its removal runs.
    func isLibraryItemLive(_ item: MediaItem, in context: ModelContext) -> Bool {
        deletedItemIDs.contains(item.id) == false && item.isDeleted == false && item.modelContext === context
    }

    func hasAvailableFile(for items: [MediaItem], in context: ModelContext) async -> Bool {
        let liveItems = items.filter { isLibraryItemLive($0, in: context) }
        guard liveItems.isEmpty == false else { return false }
        let references = liveItems.map(fileReference(for:))
        let availableIDs = await Task.detached(priority: .utility) { [self] in
            let available = references.filter {
                (try? MediaImportFingerprint.fileSize(of: resolvedURL(for: $0))) != nil
            }
            return Set(available.map(\.id))
        }.value
        return liveItems.contains { availableIDs.contains($0.id) && isLibraryItemLive($0, in: context) }
    }

    /// Libraries imported before fingerprints existed can hold thousands of items, so every bookmark is
    /// resolved in the worker and the resolved URL is kept for the fingerprint comparison.
    func groupImportCandidatesBySize(
        _ items: [MediaItem]
    ) async -> [UInt64: [(item: MediaItem, url: URL)]] {
        let references = items.map(fileReference(for:))
        let files = await Task.detached(priority: .utility) { [self] in
            var files: [UUID: (url: URL, size: UInt64)] = [:]
            for reference in references {
                let url = resolvedURL(for: reference)
                if let size = try? MediaImportFingerprint.fileSize(of: url) {
                    files[reference.id] = (url, size)
                }
            }
            return files
        }.value
        var grouped: [UInt64: [(item: MediaItem, url: URL)]] = [:]
        for item in items {
            if let file = files[item.id] { grouped[file.size, default: []].append((item, file.url)) }
        }
        return grouped
    }
}

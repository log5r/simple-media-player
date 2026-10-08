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

    /// Removes the file in a worker before the item, as before, so an interrupted deletion leaves a row with
    /// a missing file instead of an untracked file. Imports ignore the item as soon as the deletion starts.
    func delete(_ item: MediaItem, from context: ModelContext) async {
        let itemID = item.id
        guard deletedItemIDs.insert(itemID).inserted else { return }
        let reference = fileReference(for: item)
        await Task.detached(priority: .utility) { [self] in
            let url = resolvedURL(for: reference)
            if let cacheURL = ExtendedAudioSource.cacheURL(for: url) {
                ExtendedAudioSource.removeCacheInBackground(at: cacheURL)
            }
            try? FileManager.default.removeItem(at: url)
        }.value
        guard item.isDeleted == false, item.modelContext === context else { return }
        let linkedEntries = FetchDescriptor<PlaylistEntry>(predicate: #Predicate { $0.item?.id == itemID })
        guard let entries = try? context.fetch(linkedEntries) else { return }
        // The unidirectional item relationship has no inverse to nullify on deletion.
        for entry in entries { entry.item = nil }
        context.delete(item)
        try? context.save()
    }

    /// Checked after every awaited probe: an item being deleted can still have its file during the probe.
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

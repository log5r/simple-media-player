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

    /// Removes the item from the library immediately and its file in the returned background task.
    @discardableResult
    func delete(_ item: MediaItem, from context: ModelContext) -> Task<Void, Never>? {
        let itemID = item.id
        let linkedEntries = FetchDescriptor<PlaylistEntry>(predicate: #Predicate { $0.item?.id == itemID })
        guard let entries = try? context.fetch(linkedEntries) else { return nil }
        // The unidirectional item relationship has no inverse to nullify on deletion.
        for entry in entries { entry.item = nil }
        let reference = fileReference(for: item)
        context.delete(item)
        try? context.save()
        // Managed file names are unique per item, so a late removal cannot reach a newer import.
        let removal = Task.detached(priority: .utility) { [self] in
            let url = resolvedURL(for: reference)
            if let cacheURL = ExtendedAudioSource.cacheURL(for: url) {
                ExtendedAudioSource.removeCacheInBackground(at: cacheURL)
            }
            try? FileManager.default.removeItem(at: url)
        }
        pendingFileRemovals[itemID] = removal
        Task { [weak self] in
            await removal.value
            if self?.pendingFileRemovals[itemID] == removal { self?.pendingFileRemovals[itemID] = nil }
        }
        return removal
    }

    func waitForPendingFileRemovals() async {
        while let (itemID, removal) = pendingFileRemovals.first {
            await removal.value
            if pendingFileRemovals[itemID] == removal { pendingFileRemovals[itemID] = nil }
        }
    }

    func hasAvailableFile(for items: [MediaItem]) async -> Bool {
        guard items.isEmpty == false else { return false }
        let references = items.map(fileReference(for:))
        return await Task.detached(priority: .utility) { [self] in
            references.contains { (try? MediaImportFingerprint.fileSize(of: resolvedURL(for: $0))) != nil }
        }.value
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

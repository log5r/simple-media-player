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
            id: itemID, bookmarkData: item.bookmarkData, fileName: item.fileName, libraryID: libraryID
        )
        deletedItemIDs.insert(itemID)
        removalJournal.add(removal)
        deleteLibraryModel(item, from: context)
        try? context.save()
        // Managed file names are unique per item, so a late removal cannot reach a newer import.
        return Task.detached(priority: .utility) { [self] in
            await FileSystemWorkQueue.run { [self] in removeFile(for: removal) }
        }
    }

    /// Drops items an import inserted but could not save, so they are not reported as imported, and removes
    /// their copied files in the background. The journal lets the next launch retry an interrupted removal.
    func discardUnsavedImports(
        _ items: [MediaItem], from context: ModelContext, summary: inout MediaImportSummary
    ) {
        summary.createdCount = 0
        let removals = items.map { item in
            PendingFileRemovalJournal.Entry(
                id: item.id, bookmarkData: item.bookmarkData, fileName: item.fileName, libraryID: libraryID
            )
        }
        for (item, removal) in zip(items, removals) {
            deletedItemIDs.insert(item.id)
            removalJournal.add(removal)
            deleteLibraryModel(item, from: context)
        }
        Task.detached(priority: .utility) { [self] in
            await FileSystemWorkQueue.run { [self] in
                for removal in removals { removeFile(for: removal) }
            }
        }
    }

    /// End the insertion-only interval before any MediaItem removal, including failed saves.
    func deleteLibraryModel(_ item: MediaItem, from context: ModelContext) {
        latestImportInsertion = nil
        context.delete(item)
    }

    /// Finishes removals recorded by earlier launches; call once when the app starts.
    @discardableResult
    func resumePendingFileRemovals() -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            await FileSystemWorkQueue.run { [self] in
                let mediaDirectory = mediaDirectoryURL()
                for removal in removalJournal.entries(forLibrary: libraryID, mediaDirectory: mediaDirectory) {
                    removeFile(for: removal)
                }
                for legacy in removalJournal.legacyEntries(outside: mediaDirectory) {
                    guard let removal = adoptedLegacyRemoval(legacy, in: mediaDirectory) else { continue }
                    removalJournal.add(removal)
                    removeFile(for: removal)
                }
            }
        }
    }

    /// An entry of the earlier format whose path is outside the media directory belongs to this library only if
    /// its bookmark resolves to a file that exists directly in the directory, as when iOS moved the app's
    /// container. Such an entry is rewritten by name; any other is left, as it may be another library's.
    private nonisolated func adoptedLegacyRemoval(
        _ entry: PendingFileRemovalJournal.Entry, in mediaDirectory: URL
    ) -> PendingFileRemovalJournal.Entry? {
        guard case let .legacyPath(path) = entry.location else { return nil }
        // The old path is outside the directory, so a bookmark that does not resolve falls back outside it too.
        let url = resolveBookmark(entry.bookmarkData, URL(fileURLWithPath: path))
        guard PendingFileRemovalJournal.isDirectlyInside(mediaDirectory, url),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return PendingFileRemovalJournal.Entry(
            id: entry.id, bookmarkData: entry.bookmarkData, fileName: url.lastPathComponent, libraryID: libraryID,
            recordedPath: path
        )
    }

    /// Blocks on the file system, so callers run it on `FileSystemWorkQueue`.
    ///
    /// The file is reached only by its bookmark or by its name in the current media directory. A file whose
    /// bookmark resolves to a path that no longer exists, as after iOS moves the app's container, is removed by
    /// its name instead. The entry stays journaled unless a file was removed or every location is missing.
    nonisolated func removeFile(for removal: PendingFileRemovalJournal.Entry) {
        // Earlier-format entries are checked and turned into names when they are selected. An unchecked path
        // could name a file outside the library, so its entry is left for a later launch.
        guard case let .managed(fileName, _) = removal.location else { return }
        let fallbackURL = fallbackMediaURL(forFileName: fileName)
        let url = resolveBookmark(removal.bookmarkData, fallbackURL)
        var candidates = [url]
        if url.standardizedFileURL.path != fallbackURL.standardizedFileURL.path {
            candidates.append(fallbackURL)
        }
        // Caches key a file by its path as written, so each of these that names the removed file has entries.
        let spellings = [url, fallbackURL] + (removal.recordedPath.map { [URL(fileURLWithPath: $0)] } ?? [])
        for candidate in candidates {
            switch Self.removeFileAndDerivedEntries(at: candidate, spellings: spellings) {
            case .removed:
                removalJournal.remove(id: removal.id)
                return
            case .missing:
                continue
            case .failed:
                return
            }
        }
        // Every location is already gone.
        removalJournal.remove(id: removal.id)
    }

    private enum FileRemovalOutcome { case removed, missing, failed }

    /// Removes one location of a managed file and the cache entries derived from that location, so when a
    /// stale bookmark sends the removal to a second location, each location's entries go with its own file.
    /// The caches key a file by its path as written, so the entries of each of `spellings` that names the same
    /// file, compared by device and inode rather than by path, are removed too.
    private nonisolated static func removeFileAndDerivedEntries(
        at url: URL, spellings: [URL]
    ) -> FileRemovalOutcome {
        var originals = [url]
        if let identity = fileIdentity(of: url) {
            originals += spellings.filter { fileIdentity(of: $0) == identity }
        }
        let decodedCaches = Set(originals.compactMap {
            ExtendedAudioSource.cacheURL(forOriginalURL: $0, attributesOf: url)
        })
        for cacheURL in decodedCaches {
            ExtendedAudioSource.removeCacheInBackground(at: cacheURL)
        }
        // These entries are keyed by the file's path and attributes, so nothing can find them once the file is
        // gone. The keys need the file, so they are read first; the entries are removed after the file, so a
        // loudness measurement that stores while the file is removed either finds it gone or is removed here.
        let derivedEntries = Set(originals.flatMap { original in
            [
                MusicAnalysisCache.entryURL(forOriginalURL: original, attributesOf: url),
                AudioLoudnessCache.entryURL(forOriginalURL: original, attributesOf: url)
            ].compactMap(\.self)
        })
        let outcome: FileRemovalOutcome
        do {
            try FileManager.default.removeItem(at: url)
            outcome = .removed
        } catch {
            // Keep the entries with a file that is still there, so the retry can read their keys again.
            guard isMissingFileError(error) else { return .failed }
            outcome = .missing
        }
        for entry in derivedEntries {
            try? FileManager.default.removeItem(at: entry)
        }
        return outcome
    }

    nonisolated private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private nonisolated static func fileIdentity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Only a missing file needs no retry. Any other failure keeps the journal entry, even when the file's
    /// existence cannot be checked either, as when the media directory loses its search permission.
    nonisolated static func isMissingFileError(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileNoSuchFile.rawValue { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
    }

    /// Checked after every awaited probe: a deleted item's file can outlive the item until its removal runs.
    func isLibraryItemLive(_ item: MediaItem, in context: ModelContext) -> Bool {
        deletedItemIDs.contains(item.id) == false && item.isDeleted == false && item.modelContext === context
    }

    /// Stops waiting when the caller is cancelled; the abandoned probe keeps its `limiter` slot until it
    /// finishes, so cancel-and-retry cycles cannot pile up probes on a slow volume.
    func hasAvailableFileCancellable(
        for items: [MediaItem], in context: ModelContext, limiter: FileSystemWorkLimiter
    ) async throws -> Bool {
        guard let probe = availableFileProbe(for: items, in: context) else { return false }
        let availableIDs = try await FileSystemWorkQueue.runCancellable(
            qos: .userInitiated, limiter: limiter, probe.work
        )
        try Task.checkCancellation()
        return probe.liveItems.contains { availableIDs.contains($0.id) && isLibraryItemLive($0, in: context) }
    }

    /// Captures value snapshots of the live items; the returned work resolves them off the main actor.
    private func availableFileProbe(
        for items: [MediaItem], in context: ModelContext
    ) -> (liveItems: [MediaItem], work: @Sendable () -> Set<UUID>)? {
        let liveItems = items.filter { isLibraryItemLive($0, in: context) }
        guard liveItems.isEmpty == false else { return nil }
        let references = liveItems.map(fileReference(for:))
        return (liveItems, { [self] in
            let available = references.filter {
                (try? MediaImportFingerprint.fileSize(of: resolvedURL(for: $0))) != nil
            }
            return Set(available.map(\.id))
        })
    }

    /// Libraries imported before fingerprints existed can hold thousands of items, so every bookmark is
    /// resolved in the worker and the resolved URL is kept for the fingerprint comparison.
    /// A cancelled import stops waiting at once, and the worker stops before the next candidate; the abandoned
    /// worker keeps its slot of the import's limiter until then.
    func groupImportCandidatesBySize(
        _ items: [MediaItem]
    ) async throws -> [UInt64: [(item: MediaItem, url: URL)]] {
        let references = items.map(fileReference(for:))
        let stop = FileWorkStopSignal()
        let files = try await withTaskCancellationHandler {
            try await FileSystemWorkQueue.runCancellable(limiter: importFileLimiter) { [self] in
                var files: [UUID: (url: URL, size: UInt64)] = [:]
                for reference in references {
                    guard stop.isRequested == false else { break }
                    let url = resolvedURL(for: reference)
                    if let size = try? MediaImportFingerprint.fileSize(of: url) {
                        files[reference.id] = (url, size)
                    }
                }
                return files
            }
        } onCancel: {
            stop.request()
        }
        try Task.checkCancellation()
        var grouped: [UInt64: [(item: MediaItem, url: URL)]] = [:]
        for item in items {
            if let file = files[item.id] { grouped[file.size, default: []].append((item, file.url)) }
        }
        return grouped
    }
}

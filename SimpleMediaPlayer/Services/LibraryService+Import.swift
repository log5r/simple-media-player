import Foundation
import SwiftData

extension LibraryService {
    /// `overrides` carry values that take precedence over the file's embedded metadata, keyed by source URL.
    @discardableResult
    func importFiles(
        from urls: [URL], overrides: [URL: MediaImportOverride] = [:],
        into context: ModelContext, existingItems: [MediaItem]
    ) async -> MediaImportSummary {
        guard urls.isEmpty == false else { return MediaImportSummary() }

        let previousTask = importTask?.task
        let requestID = UUID()
        let task = Task { @MainActor in
            self.importRequestStarted()
            _ = await previousTask?.value
            return await self.performImport(
                from: urls, overrides: overrides, into: context, existingItems: existingItems
            )
        }
        importTask = (requestID, task)
        let summary = await task.value
        if importTask?.id == requestID { importTask = nil }
        return summary
    }

    private func performImport(
        from urls: [URL], overrides: [URL: MediaImportOverride],
        into context: ModelContext, existingItems: [MediaItem]
    ) async -> MediaImportSummary {
        beginImportProgress(totalCount: urls.count)
        // Imports are serialized, so `lastImportErrors` belongs to this request until it returns.
        var summary = MediaImportSummary()
        defer {
            summary.errors = lastImportErrors
            finishImportProgress()
        }

        var duplicateIndex: ImportIndex
        do {
            duplicateIndex = ImportIndex(items: try importItems(existingItems, in: context))
        } catch {
            lastImportErrors.append(error.localizedDescription)
            return MediaImportSummary(errors: lastImportErrors)
        }
        let musicSession = musicMetadataProvider.makeSession()
        var createdItems: [MediaItem] = []

        for (index, url) in urls.enumerated() {
            currentImportFileName = url.lastPathComponent
            importProgress = Double(index) / Double(urls.count)
            await Task.yield()

            do {
                if let item = try await importFile(
                    from: url, override: overrides[url], in: context, session: musicSession, index: &duplicateIndex
                ) {
                    summary.createdCount += 1
                    createdItems.append(item)
                } else {
                    summary.duplicateCount += 1
                }
            } catch {
                lastImportErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            importCompletedFileCount = index + 1
            importProgress = Double(index + 1) / Double(urls.count)
        }

        do {
            try saveContext(context)
        } catch {
            lastImportErrors.append(L10n.format("Could not save: %@", error.localizedDescription))
            discardUnsavedImports(createdItems, from: context, summary: &summary)
        }
        summary.errors = lastImportErrors
        return summary
    }

    private func importFile(
        from url: URL, override: MediaImportOverride?, in context: ModelContext,
        session: MusicLibraryMetadataSession, index: inout ImportIndex
    ) async throws -> MediaItem? {
        let fingerprint = try await importFingerprint(for: url)
        var isDuplicate = await hasAvailableFile(for: index.byFingerprint[fingerprint] ?? [], in: context)
        if !isDuplicate, !index.legacyItems.isEmpty {
            if index.legacyItemsBySize == nil {
                index.legacyItemsBySize = await groupImportCandidatesBySize(index.legacyItems)
            }
            var fingerprints = index.byFingerprint
            do {
                isDuplicate = try await hasMatchingLegacyFile(
                    (url, fingerprint), candidates: index.legacyItemsBySize ?? [:],
                    index: &fingerprints, context: context
                )
            } catch {
                index.byFingerprint = fingerprints
                throw error
            }
            index.byFingerprint = fingerprints
        }
        // Exports of the same Music song never share bytes, so the song ID is checked here too.
        let isMusicDuplicate = await isMusicLibraryDuplicate(override, in: index.byMusicID, context: context)
        guard !isDuplicate, !isMusicDuplicate else { return nil }
        let (item, importedValues) = try await makeMediaItem(
            from: url, importFingerprint: fingerprint, musicSession: session
        )
        await apply(override, to: item, importedValues: importedValues)
        await beforeImportRegistration(url)
        context.insert(item)
        index.insert(item)
        return item
    }

    private func importItems(_ existing: [MediaItem], in context: ModelContext) throws -> [MediaItem] {
        var items: [UUID: MediaItem] = [:]
        for item in existing { items[item.id] = item }
        for item in try context.fetch(FetchDescriptor<MediaItem>()) { items[item.id] = item }
        return Array(items.values)
    }

    private func hasMatchingLegacyFile(
        _ source: (url: URL, fingerprint: String), candidates: [UInt64: [(item: MediaItem, url: URL)]],
        index: inout [String: [MediaItem]], context: ModelContext
    ) async throws -> Bool {
        let size = try await Task.detached(priority: .utility) {
            try MediaImportFingerprint.fileSize(of: source.url)
        }.value
        for (candidate, url) in candidates[size] ?? [] where candidate.importFingerprint == nil {
            guard let fingerprint = try? await importFingerprint(for: url), isLibraryItemLive(candidate, in: context)
            else { continue }
            candidate.importFingerprint = fingerprint
            index[fingerprint, default: []].append(candidate)
            if fingerprint == source.fingerprint { return true }
        }
        return false
    }

    /// Applied before the item is inserted. Override values replace the embedded ones; a nil text
    /// field keeps the embedded value unless the override replaces the whole set, and nil lyrics or
    /// artwork keep the embedded ones. When the override could not be written into the file, the item
    /// records the text, lyrics, and artwork as edited so later edits start from these values, not the file's tags.
    /// `importedValues` are the merged import values, with a nil artist or album when no source has one.
    private func apply(
        _ override: MediaImportOverride?, to item: MediaItem, importedValues: MediaMetadataEmbeddedValues
    ) async {
        guard let override else { return }
        var values = override.values
        if override.replacesTextFields {
            values.title = values.title ?? item.title
            values.artist = values.artist ?? "Unknown Artist"
            values.album = values.album ?? "Unknown Album"
            values.isCompilation = values.isCompilation ?? false
        }
        applyPrimaryValues(values, replacesAll: override.replacesTextFields, to: item)
        applySecondaryValues(values, replacesAll: override.replacesTextFields, to: item)
        if let lyrics = override.lyrics { item.lyricsRaw = lyrics }
        var storedArtwork = false
        if let artwork = override.artworkData, let thumbnail = await artworkProcessor.thumbnail(from: artwork) {
            item.artworkData = thumbnail
            storedArtwork = true
        }
        item.musicLibraryItemID = override.musicLibraryItemID ?? item.musicLibraryItemID
        if override.isEmbeddedInFile == false {
            // The draft reads `Unknown Artist` and `Unknown Album` as display fallbacks, but a value from the
            // override or the file with that text is literal and stays an edit of that text.
            var draft = MediaMetadataEditDraft(item: item)
            let artist = override.values.artist ?? (override.replacesTextFields ? nil : importedValues.artist)
            let album = override.values.album ?? (override.replacesTextFields ? nil : importedValues.album)
            if artist == "Unknown Artist" { draft.artist = "Unknown Artist" }
            if album == "Unknown Album" { draft.album = "Unknown Album" }
            item.setEditedTextMetadata(draft)
            if override.lyrics != nil { item.setEditedLyrics(item.lyricsRaw) }
            item.hasEditedArtwork = storedArtwork
        }
    }

    /// Runs inside the serialized import, so a second request for the same song that was queued
    /// before the first one registered its item still sees that item.
    private func isMusicLibraryDuplicate(
        _ override: MediaImportOverride?, in itemsByMusicID: [String: [MediaItem]], context: ModelContext
    ) async -> Bool {
        guard let musicID = override?.musicLibraryItemID, let items = itemsByMusicID[musicID] else { return false }
        return await hasAvailableFile(for: items, in: context)
    }

    private func applyPrimaryValues(
        _ values: MediaMetadataEmbeddedValues, replacesAll: Bool, to item: MediaItem
    ) {
        if let title = values.title { item.title = title }
        if let artist = values.artist { item.artist = artist }
        if let album = values.album { item.album = album }
        if replacesAll || values.genre != nil { item.genre = values.genre }
        if replacesAll || values.year != nil { item.year = values.year }
        if replacesAll || values.trackNumber != nil { item.trackNumber = values.trackNumber }
    }

    private func applySecondaryValues(
        _ values: MediaMetadataEmbeddedValues, replacesAll: Bool, to item: MediaItem
    ) {
        if replacesAll || values.comment != nil { item.comment = values.comment }
        if replacesAll || values.albumArtist != nil { item.albumArtist = values.albumArtist }
        if replacesAll || values.composer != nil { item.composer = values.composer }
        if replacesAll || values.discNumber != nil { item.discNumber = values.discNumber }
        if let isCompilation = values.isCompilation { item.isCompilation = isCompilation }
    }

    private func beginImportProgress(totalCount: Int) {
        isImporting = true
        importProgress = 0
        importCompletedFileCount = 0
        importTotalFileCount = totalCount
        currentImportFileName = nil
        lastImportErrors = []
        didReportMusicLibraryAccessFailure = false
    }

    private func finishImportProgress() {
        isImporting = false
        importProgress = 1
        importCompletedFileCount = importTotalFileCount
        currentImportFileName = nil
    }

    private func importFingerprint(for url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try MediaImportFingerprint.read(from: url)
        }.value
    }

}

@MainActor
private struct ImportIndex {
    var byFingerprint: [String: [MediaItem]] = [:]
    var byMusicID: [String: [MediaItem]] = [:]
    let legacyItems: [MediaItem]
    var legacyItemsBySize: [UInt64: [(item: MediaItem, url: URL)]]?

    init(items: [MediaItem]) {
        legacyItems = items.filter { $0.importFingerprint == nil }
        for item in items { insert(item) }
    }

    mutating func insert(_ item: MediaItem) {
        if let fingerprint = item.importFingerprint {
            byFingerprint[fingerprint, default: []].append(item)
        }
        if let musicID = item.musicLibraryItemID {
            byMusicID[musicID, default: []].append(item)
        }
    }
}

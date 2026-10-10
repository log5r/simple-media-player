import AVFoundation
import CoreMedia
import Foundation
import SwiftData
import UniformTypeIdentifiers

struct BulkMetadataEditFailure: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let message: String
}

struct BulkMetadataEditResult: Sendable {
    var updatedCount: Int
    var failures: [BulkMetadataEditFailure]
    /// Items left untouched because the request was cancelled before they were written.
    var unprocessedCount = 0

    var failedCount: Int {
        failures.count
    }
}

struct BulkMetadataEditProgress: Equatable, Sendable {
    /// Items that finished, whether updated or failed.
    let completedCount: Int
    let totalCount: Int
}

@MainActor
@Observable
final class LibraryService {
    @ObservationIgnored nonisolated private let mediaDirectoryOverride: URL?
    @ObservationIgnored nonisolated let temporaryDirectoryURL: URL
    @ObservationIgnored private let artworkProcessor: ArtworkProcessor
    @ObservationIgnored let artworkLoader: LibraryArtworkLoader
    @ObservationIgnored private let lyricsReader: EmbeddedLyricsReader
    @ObservationIgnored private let musicMetadataProvider: MusicLibraryMetadataProvider
    @ObservationIgnored private let editabilityChecker: EmbeddedMetadataEditabilityChecker
    @ObservationIgnored nonisolated let resolveBookmark: @Sendable (Data, URL) -> URL
    @ObservationIgnored nonisolated let removalJournal: PendingFileRemovalJournal
    @ObservationIgnored private let saveContext: @MainActor (ModelContext) throws -> Void
    /// Shared by every export plan, so resolutions left running by a cancelled plan still count.
    @ObservationIgnored nonisolated let exportPlanLimiter = FileSystemWorkLimiter(limit: exportPlanConcurrency)
    /// Shared by Music import pre-checks, so probes abandoned by cancelled preparations still count.
    @ObservationIgnored nonisolated let musicLibraryProbeLimiter = FileSystemWorkLimiter(limit: 2)
    @ObservationIgnored private var lyricsLoadRequests: [UUID: UUID] = [:]
    @ObservationIgnored private var importTask: (id: UUID, task: Task<MediaImportSummary, Never>)?
    /// Deleted items can stay in import snapshots while their files are removed in the background.
    @ObservationIgnored var deletedItemIDs: Set<UUID> = []

    var isImporting = false
    var importProgress = 0.0
    var importCompletedFileCount = 0
    var importTotalFileCount = 0
    var currentImportFileName: String?
    var lastImportErrors: [String] = []
    var isExporting = false
    var exportProgress = 0.0
    var exportCompletedFileCount = 0
    var exportTotalFileCount = 0
    var currentExportFileName: String?
    var lastExportErrors: [String] = []
    var exportPlanPreparation: ExportPlanPreparation?
    var musicLibraryPreparation: MusicLibraryPreparation?
    private var didReportMusicLibraryAccessFailure = false

    private static let lyricsKeyNeedles = ["lyrics", "ult", "uslt", "sylt", "©lyr", "lyr"]
    private static let compilationKeyNeedles = ["compilation", "cpil", "tcmp", "tcp"]

    private static func firstNonblank(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    init(
        mediaDirectoryURL: URL? = nil,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        artworkProcessor: ArtworkProcessor = ArtworkProcessor(),
        lyricsReader: EmbeddedLyricsReader = EmbeddedLyricsReader(),
        artworkLoader: LibraryArtworkLoader = .shared,
        editabilityChecker: EmbeddedMetadataEditabilityChecker = EmbeddedMetadataEditabilityChecker(),
        musicMetadataProvider: MusicLibraryMetadataProvider = MusicLibraryMetadataProvider(),
        resolveBookmark: @escaping @Sendable (Data, URL) -> URL = EmbeddedMetadataEditabilityChecker.resolve,
        removalJournal: PendingFileRemovalJournal = PendingFileRemovalJournal(),
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        mediaDirectoryOverride = mediaDirectoryURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.resolveBookmark = resolveBookmark
        self.removalJournal = removalJournal
        self.saveContext = saveContext
        self.artworkProcessor = artworkProcessor
        self.lyricsReader = lyricsReader
        self.artworkLoader = artworkLoader
        self.editabilityChecker = editabilityChecker
        self.musicMetadataProvider = musicMetadataProvider
    }

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

        var itemsByID: [UUID: MediaItem] = [:]
        do {
            for item in existingItems { itemsByID[item.id] = item }
            for item in try context.fetch(FetchDescriptor<MediaItem>()) { itemsByID[item.id] = item }
        } catch {
            lastImportErrors.append(error.localizedDescription)
            return MediaImportSummary(errors: lastImportErrors)
        }
        var itemsByFingerprint: [String: [MediaItem]] = [:]
        var itemsByMusicID: [String: [MediaItem]] = [:]
        for item in itemsByID.values {
            Self.index(item, in: &itemsByFingerprint, &itemsByMusicID)
        }
        let legacyItems = itemsByID.values.filter { $0.importFingerprint == nil }
        var legacyItemsBySize: [UInt64: [(item: MediaItem, url: URL)]]?
        let musicSession = musicMetadataProvider.makeSession()
        var createdItems: [MediaItem] = []

        for (index, url) in urls.enumerated() {
            currentImportFileName = url.lastPathComponent
            importProgress = Double(index) / Double(urls.count)
            await Task.yield()

            do {
                let fingerprint = try await importFingerprint(for: url)
                var isDuplicate = await hasAvailableFile(for: itemsByFingerprint[fingerprint] ?? [], in: context)
                if isDuplicate == false, legacyItems.isEmpty == false {
                    if legacyItemsBySize == nil {
                        legacyItemsBySize = await groupImportCandidatesBySize(legacyItems)
                    }
                    let size = try await Task.detached(priority: .utility) {
                        try MediaImportFingerprint.fileSize(of: url)
                    }.value
                    for (candidate, candidateURL) in legacyItemsBySize?[size] ?? []
                    where candidate.importFingerprint == nil {
                        guard let candidateFingerprint = try? await importFingerprint(for: candidateURL),
                              isLibraryItemLive(candidate, in: context)
                        else { continue }
                        candidate.importFingerprint = candidateFingerprint
                        itemsByFingerprint[candidateFingerprint, default: []].append(candidate)
                        if candidateFingerprint == fingerprint {
                            isDuplicate = true
                            break
                        }
                    }
                }
                // Exports of the same Music song never share bytes, so the song ID is checked here too.
                let isMusicDuplicate = await isMusicLibraryDuplicate(
                    overrides[url], in: itemsByMusicID, context: context
                )
                if isDuplicate || isMusicDuplicate {
                    summary.duplicateCount += 1
                } else {
                    let item = try await makeMediaItem(
                        from: url, importFingerprint: fingerprint, musicSession: musicSession
                    )
                    await apply(overrides[url], to: item)
                    context.insert(item)
                    Self.index(item, in: &itemsByFingerprint, &itemsByMusicID)
                    summary.createdCount += 1
                    createdItems.append(item)
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

    func resolvedURL(for item: MediaItem) -> URL? {
        resolvedURL(for: fileReference(for: item))
    }

    func saveLyrics(_ lyrics: String, for item: MediaItem, embedInFile: Bool, in context: ModelContext) async throws {
        // A delayed read must not restore lyrics that the user has just removed.
        lyricsLoadRequests[item.id] = nil
        let normalizedLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : lyrics

        if embedInFile {
            let itemID = item.id
            let bookmarkData = item.bookmarkData
            let fileName = item.fileName
            guard let url = resolvedURL(for: item) else {
                throw MediaMetadataEditError.cannotResolveFile
            }
            let canWriteMetadata = try await editabilityChecker.canWriteMetadata(to: url)
            guard item.id == itemID, item.bookmarkData == bookmarkData, item.fileName == fileName,
                  item.isDeleted == false, item.modelContext === context else { throw CancellationError() }
            guard canWriteMetadata else {
                throw MediaMetadataEditError.unsupportedFileFormat
            }

            var draft = MediaMetadataEditDraft(item: item)
            draft.lyrics = normalizedLyrics ?? ""
            draft.editsTextMetadata = false
            draft.editsArtwork = false
            draft.editsLyrics = true

            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            try await Task.detached(priority: .utility) {
                if ID3TagWriter.canWriteMetadata(to: url) {
                    try ID3TagWriter.write(draft, to: url)
                } else if MP4MetadataWriter.canWriteMetadata(to: url) {
                    try MP4MetadataWriter.write(draft, to: url)
                } else if AIFFMetadataWriter.canWriteMetadata(to: url) {
                    try AIFFMetadataWriter.write(draft, to: url)
                } else {
                    try AdditionalAudioMetadata.write(draft, to: url)
                }
            }.value
        }

        let previousLyrics = (raw: item.lyricsRaw, edited: item.hasEditedLyrics)
        item.setEditedLyrics(normalizedLyrics)
        do {
            try context.save()
        } catch {
            item.lyricsRaw = previousLyrics.raw
            item.hasEditedLyrics = previousLyrics.edited
            throw error
        }
    }

    /// Pass `includesArtwork: false` when the draft's artwork is never written (it is only written
    /// with `editsArtwork`), so neither the library artwork nor the embedded MP4 artwork is decoded.
    func editableMetadataDraft(
        for item: MediaItem, includesArtwork: Bool = true
    ) async throws -> MediaMetadataEditDraft {
        try Task.checkCancellation()
        var draft = MediaMetadataEditDraft(item: item)
        draft.artworkData = try await libraryArtworkForDraft(of: item, includesArtwork: includesArtwork)
        try Task.checkCancellation()
        let storedArtwork = draft.artworkData
        guard let url = resolvedURL(for: item) else {
            return draftPreservingStoredEdits(draft, for: item, storedArtwork: storedArtwork)
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        if let info = try? await ExtendedAudioSource.probeInfo(for: url) {
            try Task.checkCancellation()
            return draftPreservingStoredEdits(
                draftByApplyingExtendedInfo(info, to: draft), for: item, storedArtwork: storedArtwork
            )
        }
        try Task.checkCancellation()

        let metadata = await allMetadata(for: AVURLAsset(url: url))
        try Task.checkCancellation()
        let metadataValues = await metadata.embeddedValues(compilationKeyNeedles: Self.compilationKeyNeedles)
        try Task.checkCancellation()
        draft = draft.applying(metadataValues)
        draft = try await draftByApplyingMP4Metadata(to: draft, for: url, includesArtwork: includesArtwork)

        if ID3TagWriter.canWriteMetadata(to: url),
           let values = try? await Task.detached(priority: .utility, operation: {
               try ID3TagWriter.readMetadata(from: url)
           }).value {
            try Task.checkCancellation()
            draft = draft.applying(values)
        }
        try Task.checkCancellation()

        if let embedded = try? await Task.detached(priority: .utility, operation: {
               guard AdditionalAudioMetadata.canWrite(to: url) else { return nil as AudioTagReadResult? }
               return try AdditionalAudioMetadata.read(from: url)
           }).value {
            try Task.checkCancellation()
            draft = draft.applying(embedded.values)
            if let artwork = embedded.artworkData { draft.artworkData = artwork }
            if let lyrics = embedded.lyrics { draft.lyrics = lyrics }
        }

        try Task.checkCancellation()
        return draftPreservingStoredEdits(draft, for: item, storedArtwork: storedArtwork)
    }

    func loadArtwork(from url: URL) async throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        return try await artworkProcessor.load(from: url)
    }

    func updateEmbeddedMetadata(
        for item: MediaItem,
        draft: MediaMetadataEditDraft,
        in context: ModelContext
    ) async throws {
        let itemID = item.id
        let bookmarkData = item.bookmarkData
        let fileName = item.fileName
        guard let url = resolvedURL(for: item) else {
            if draft.editsArtwork {
                item.artworkData = draft.artworkData
                try saveContext(context)
                return
            }
            throw MediaMetadataEditError.cannotResolveFile
        }
        let canWriteMetadata = try await editabilityChecker.canWriteMetadata(to: url)
        guard item.id == itemID, item.bookmarkData == bookmarkData, item.fileName == fileName,
              item.isDeleted == false, item.modelContext === context else { throw CancellationError() }
        guard canWriteMetadata || draft.editsArtwork else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        if canWriteMetadata {
            try await Task.detached(priority: .utility) {
                if ID3TagWriter.canWriteMetadata(to: url) {
                    try ID3TagWriter.write(draft, to: url)
                } else if MP4MetadataWriter.canWriteMetadata(to: url) {
                    try MP4MetadataWriter.write(draft, to: url)
                } else if AIFFMetadataWriter.canWriteMetadata(to: url) {
                    try AIFFMetadataWriter.write(draft, to: url)
                } else {
                    try AdditionalAudioMetadata.write(draft, to: url)
                }
            }.value
        }

        applyMetadataValues(draft, to: item, fileURL: url, canWriteMetadata: canWriteMetadata)
        try saveContext(context)
    }

    private func applyMetadataValues(
        _ draft: MediaMetadataEditDraft, to item: MediaItem, fileURL url: URL, canWriteMetadata: Bool
    ) {
        if canWriteMetadata && draft.editsTextMetadata {
            item.applyTextValues(of: draft, fileURL: url)
            item.setEditedTextMetadata(draft)
        }
        if draft.editsArtwork {
            item.artworkData = draft.artworkData
            // Unwritable formats keep the edit only on the item, so it must outrank the file's artwork.
            if canWriteMetadata == false { item.hasEditedArtwork = true }
        }
        if draft.editsLyrics {
            item.setEditedLyrics(draft.lyrics)
        }
    }

}

extension LibraryService {
    func loadMediaInfo(for item: MediaItem) async -> MediaInfoDetails {
        let snapshot = MediaInfoItemSnapshot(item: item)
        let reference = fileReference(for: item)
        // Callers discard results of superseded requests, so a cancelled load returns no details.
        guard let url = try? await FileSystemWorkQueue.runCancellable(qos: .userInitiated, { [self] in
            resolvedURL(for: reference)
        }) else { return .empty }
        return await MediaInfoInspector.loadDetails(for: snapshot, url: url)
    }

    func editableMetadataItemIDs(for items: [MediaItem]) async throws -> Set<UUID> {
        try Task.checkCancellation()
        let inputs = items.map(fileReference(for:))
        return try await editabilityChecker.editableIDs(for: inputs) { self.mediaDirectoryURL() }
    }

    func canEditEmbeddedMetadata(for item: MediaItem) async throws -> Bool {
        let itemID = item.id
        return try await editableMetadataItemIDs(for: [item]).contains(itemID)
    }

    /// Items are written one at a time. Cancelling the calling task stops before the next item; an item
    /// whose file write has started still finishes and counts as updated, or as failed if the write or
    /// save fails. Only the items that were never attempted count as unprocessed.
    func updateEmbeddedMetadata(
        for items: [MediaItem],
        patch: MediaMetadataEditPatch,
        in context: ModelContext,
        progress: @MainActor (BulkMetadataEditProgress) -> Void = { _ in }
    ) async -> BulkMetadataEditResult {
        var result = BulkMetadataEditResult(updatedCount: 0, failures: [])
        guard patch.isEmpty == false else { return result }

        for (index, item) in items.enumerated() {
            guard Task.isCancelled == false else {
                result.unprocessedCount = items.count - index
                break
            }
            do {
                // The writers replace only the patched fields, and unpatched artwork is never written, so the
                // patch applies to the item's values without reading the file. The draft's other text values
                // are the ones the item already shows, which it records again as its edited values.
                let patchedDraft = patch.applying(to: MediaMetadataEditDraft(item: item))
                try await updateEmbeddedMetadata(for: item, draft: patchedDraft, in: context)
                result.updatedCount += 1
            } catch {
                // Only the cancellation of a stopped request leaves this item unprocessed. Any other error
                // is a failure even after a stop, since the file may already have been rewritten; the stop
                // then takes effect before the next item. Without a stop, a cancellation means the item
                // was deleted or replaced while it was read, which is also a failure.
                if error is CancellationError, Task.isCancelled {
                    result.unprocessedCount = items.count - index
                    break
                }
                result.failures.append(
                    BulkMetadataEditFailure(fileName: item.fileName, message: error.localizedDescription)
                )
            }
            progress(BulkMetadataEditProgress(completedCount: index + 1, totalCount: items.count))
        }

        return result
    }
}

private extension LibraryService {
    /// An ordinary read failure leaves the artwork to the file's tags; cancellation or invalidation stops the draft.
    func libraryArtworkForDraft(of item: MediaItem, includesArtwork: Bool) async throws -> Data? {
        guard includesArtwork else { return nil }
        do {
            return try await libraryArtwork(for: item)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    func draftByApplyingExtendedInfo(
        _ info: ExtendedAudioSource.Info, to original: MediaMetadataEditDraft
    ) -> MediaMetadataEditDraft {
        var draft = original
        draft.title = info.title ?? draft.title
        draft.artist = info.artist ?? draft.artist
        draft.album = info.album ?? draft.album
        draft.genre = info.genre ?? draft.genre
        draft.year = info.year ?? draft.year
        draft.trackNumber = info.trackNumber ?? draft.trackNumber
        draft.comment = info.comment ?? draft.comment
        draft.albumArtist = info.albumArtist ?? draft.albumArtist
        draft.composer = info.composer ?? draft.composer
        draft.discNumber = info.discNumber ?? draft.discNumber
        draft.isCompilation = info.isCompilation
        draft.lyrics = info.lyrics ?? draft.lyrics
        // Artwork edits for extended formats live in the library item, not the source file.
        return draft
    }

    func draftByApplyingMP4Metadata(
        to original: MediaMetadataEditDraft, for url: URL, includesArtwork: Bool
    ) async throws -> MediaMetadataEditDraft {
        try Task.checkCancellation()
        let metadata = await mp4Metadata(for: url)
        try Task.checkCancellation()
        guard let metadata else { return original }
        var draft = original.applying(metadata.values)
        if includesArtwork, let embeddedArtwork = metadata.artworkData {
            let artworkData = await artworkProcessor.thumbnail(from: embeddedArtwork)
            try Task.checkCancellation()
            if let artworkData { draft.artworkData = artworkData }
        }
        return draft
    }

    /// Applied before the item is inserted. Override values replace the embedded ones; a nil text
    /// field keeps the embedded value unless the override replaces the whole set, and nil lyrics or
    /// artwork keep the embedded ones. When the override could not be written into the file, the item
    /// records the text, lyrics, and artwork as edited so later edits start from these values, not the file's tags.
    private func apply(_ override: MediaImportOverride?, to item: MediaItem) async {
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
            item.setEditedTextMetadata(MediaMetadataEditDraft(item: item))
            if override.lyrics != nil { item.setEditedLyrics(item.lyricsRaw) }
            item.hasEditedArtwork = storedArtwork
        }
    }

    private static func index(
        _ item: MediaItem, in itemsByFingerprint: inout [String: [MediaItem]],
        _ itemsByMusicID: inout [String: [MediaItem]]
    ) {
        if let fingerprint = item.importFingerprint {
            itemsByFingerprint[fingerprint, default: []].append(item)
        }
        if let musicID = item.musicLibraryItemID {
            itemsByMusicID[musicID, default: []].append(item)
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
}

extension LibraryService {
    nonisolated func fallbackMediaURL(forFileName fileName: String) -> URL {
        mediaDirectoryURL().appendingPathComponent(fileName)
    }

    private func makeMediaItem(
        from sourceURL: URL, importFingerprint: String, musicSession: MusicLibraryMetadataSession
    ) async throws -> MediaItem {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        let sources = try await readImportSources(from: sourceURL, musicSession: musicSession)
        let importValues = await mergeImportSources(sources, fileURL: sourceURL)
        let values = importValues.values
        let id = UUID()
        let copiedURL = try await copyIntoMediaDirectory(sourceURL, id: id)
        var didCreateItem = false
        defer { if didCreateItem == false { try? FileManager.default.removeItem(at: copiedURL) } }
        if sources.extended != nil {
            let validationTask = Task.detached(priority: .utility) {
                try ExtendedAudioSource.validate(for: copiedURL)
            }
            try await withTaskCancellationHandler {
                try await validationTask.value
            } onCancel: {
                validationTask.cancel()
            }
        }
        #if os(macOS)
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = try copiedURL.bookmarkData(
            options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let item = MediaItem(
            id: id,
            title: values.title ?? sourceURL.deletingPathExtension().lastPathComponent,
            artist: values.artist ?? "Unknown Artist",
            album: values.album ?? "Unknown Album",
            genre: values.genre,
            year: values.year,
            trackNumber: values.trackNumber,
            comment: values.comment,
            albumArtist: values.albumArtist,
            composer: values.composer,
            discNumber: values.discNumber,
            isCompilation: values.isCompilation ?? false,
            duration: sources.duration.isFinite ? sources.duration : 0,
            isVideo: sources.isVideo,
            lyricsRaw: importValues.lyrics,
            bookmarkData: bookmark,
            artworkData: importValues.artwork,
            fileName: copiedURL.lastPathComponent,
            importFingerprint: importFingerprint
        )
        didCreateItem = true
        return item
    }

    private func readImportSources(
        from url: URL, musicSession: MusicLibraryMetadataSession
    ) async throws -> ImportSources {
        let extended = try await ExtendedAudioSource.probeInfo(for: url)
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        if let extended {
            duration = extended.duration
        } else {
            duration = try await asset.load(.duration).seconds
        }
        let metadata = extended == nil ? await allMetadata(for: asset) : []
        let isVideo = isVideoFile(url)
        if extended == nil {
            let tracks = try await asset.load(.tracks)
            guard tracks.contains(where: { $0.mediaType == .audio || $0.mediaType == .video }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if isVideo == false { _ = try AVAudioFile(forReading: url) }
        }
        let mp4 = extended == nil ? await mp4Metadata(for: url) : nil
        let music = extended == nil ? await musicLibraryMetadata(
            for: url, mp4Metadata: mp4, duration: duration, isVideo: isVideo, session: musicSession
        ) : nil
        let id3: MediaMetadataEmbeddedValues?
        if ID3TagWriter.canWriteMetadata(to: url) {
            id3 = try? await Task.detached(priority: .utility) {
                try ID3TagWriter.readMetadata(from: url)
            }.value
        } else {
            id3 = nil
        }
        let additional: AudioTagReadResult?
        do {
            additional = try await Task.detached(priority: .utility) {
                guard AdditionalAudioMetadata.canWrite(to: url) else { return nil as AudioTagReadResult? }
                return try AdditionalAudioMetadata.read(from: url)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            additional = nil
        }
        return ImportSources(
            duration: duration, isVideo: isVideo, extended: extended,
            metadata: metadata, mp4: mp4, music: music, id3: id3, additional: additional
        )
    }

    private func mergeImportSources(_ sources: ImportSources, fileURL: URL) async -> ImportValues {
        let raw = await assetImportValues(sources.metadata)
        let extended = sources.extended
        let additional = sources.additional
        let id3 = sources.id3
        let music = sources.music
        let mp4 = sources.mp4
        let values = MediaMetadataEmbeddedValues(
            title: Self.firstNonblank(additional?.values.title, id3?.title, extended?.title,
                                      music?.title, mp4?.values.title, raw.title)
                ?? fileURL.deletingPathExtension().lastPathComponent,
            artist: Self.firstNonblank(additional?.values.artist, id3?.artist, extended?.artist,
                                       music?.artist, mp4?.values.artist, raw.artist) ?? "Unknown Artist",
            album: Self.firstNonblank(additional?.values.album, id3?.album, extended?.album,
                                      music?.album, mp4?.values.album, raw.album) ?? "Unknown Album",
            genre: Self.firstNonblank(additional?.values.genre, id3?.genre, extended?.genre,
                                      music?.genre, mp4?.values.genre, raw.genre),
            year: Self.firstNonblank(additional?.values.year, id3?.year, extended?.year,
                                     music?.year, mp4?.values.year, raw.year),
            trackNumber: Self.firstNonblank(additional?.values.trackNumber, id3?.trackNumber,
                                            extended?.trackNumber, music?.trackNumber,
                                            mp4?.values.trackNumber, raw.trackNumber),
            comment: Self.firstNonblank(additional?.values.comment, id3?.comment, extended?.comment,
                                        music?.comment, mp4?.values.comment, raw.comment),
            albumArtist: Self.firstNonblank(additional?.values.albumArtist, id3?.albumArtist,
                                            extended?.albumArtist, music?.albumArtist,
                                            mp4?.values.albumArtist, raw.albumArtist),
            composer: Self.firstNonblank(additional?.values.composer, id3?.composer, extended?.composer,
                                         music?.composer, mp4?.values.composer, raw.composer),
            discNumber: Self.firstNonblank(additional?.values.discNumber, id3?.discNumber,
                                           extended?.discNumber, music?.discNumber,
                                           mp4?.values.discNumber, raw.discNumber),
            isCompilation: additional?.values.isCompilation ?? id3?.isCompilation
                ?? extended?.isCompilation ?? music?.isCompilation
                ?? mp4?.values.isCompilation ?? raw.isCompilation ?? false
        )
        let rawLyrics = await sources.metadata.firstString(whereKeyContains: Self.lyricsKeyNeedles)
        let lyrics = sources.isVideo ? nil : additional?.lyrics ?? extended?.lyrics ?? mp4?.lyrics ?? rawLyrics
        let rawArtwork = await sources.metadata.dataValue(for: .commonIdentifierArtwork)
        let embeddedArtwork = additional?.artworkData ?? extended?.artworkData ?? mp4?.artworkData ?? rawArtwork
        let artwork: Data?
        if let embeddedArtwork {
            artwork = await artworkProcessor.thumbnail(from: embeddedArtwork)
        } else {
            artwork = nil
        }
        return ImportValues(values: values, lyrics: lyrics, artwork: artwork)
    }

    private func assetImportValues(_ metadata: [AVMetadataItem]) async -> MediaMetadataEmbeddedValues {
        MediaMetadataEmbeddedValues(
            title: await metadata.stringValue(for: .commonIdentifierTitle),
            artist: await metadata.stringValue(for: .commonIdentifierArtist),
            album: await metadata.stringValue(for: .commonIdentifierAlbumName),
            genre: await metadata.firstString(whereKeyContains: ["genre", "gnre", "tco"]),
            year: await metadata.firstDisplayString(
                whereKeyContains: ["year", "date", "tdrc", "tyer", "tye", "©day"]
            ),
            trackNumber: await metadata.firstDisplayString(
                whereKeyContains: ["track number", "tracknumber", "trck", "trk", "trkn"]
            ),
            comment: await metadata.firstDisplayString(whereKeyContains: ["comment", "comm", "©cmt"]),
            albumArtist: await metadata.firstDisplayString(
                whereKeyContains: ["album artist", "albumartist", "tpe2", "tp2", "aART"]
            ),
            composer: await metadata.firstDisplayString(whereKeyContains: ["composer", "tcom", "tcm", "©wrt"]),
            discNumber: await metadata.firstDisplayString(whereKeyContains: ["disc number", "discnumber", "disk", "tpos", "tpa"]),
            isCompilation: await metadata.firstBool(whereKeyContains: Self.compilationKeyNeedles)
        )
    }

}

extension LibraryService {
    private func importFingerprint(for url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try MediaImportFingerprint.read(from: url)
        }.value
    }

    func refreshMissingLyrics(for item: MediaItem, in context: ModelContext) async {
        guard Task.isCancelled == false,
              item.isVideo == false,
              item.hasEditedLyrics == false,
              item.lyricsRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              let url = resolvedURL(for: item) else { return }

        let itemID = item.id
        let requestID = UUID()
        let previousLyrics = item.lyricsRaw
        lyricsLoadRequests[itemID] = requestID
        defer {
            if lyricsLoadRequests[itemID] == requestID { lyricsLoadRequests[itemID] = nil }
        }

        guard let lyrics = try? await lyricsReader.read(from: url),
              Task.isCancelled == false,
              lyricsLoadRequests[itemID] == requestID,
              item.hasEditedLyrics == false,
              item.isDeleted == false,
              item.modelContext === context,
              item.lyricsRaw == previousLyrics else { return }

        item.lyricsRaw = lyrics
        do {
            try context.save()
        } catch {
            item.lyricsRaw = previousLyrics
        }
    }

    private func isVideoFile(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        }
        return type.conforms(to: .movie)
    }

    private func allMetadata(for asset: AVURLAsset) async -> [AVMetadataItem] {
        guard Task.isCancelled == false else { return [] }
        var metadata = (try? await asset.load(.metadata)) ?? []
        guard Task.isCancelled == false else { return metadata }
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            guard Task.isCancelled == false else { return metadata }
            if let formatMetadata = try? await asset.loadMetadata(for: format) {
                metadata.append(contentsOf: formatMetadata)
            }
        }
        return metadata
    }

    private func mp4Metadata(for url: URL) async -> MP4MetadataReadResult? {
        guard MP4MetadataWriter.canWriteMetadata(to: url) else { return nil }
        return try? await Task.detached(priority: .utility) {
            try MP4MetadataReader.read(from: url)
        }.value
    }

    private func musicLibraryMetadata(
        for url: URL,
        mp4Metadata: MP4MetadataReadResult?,
        duration: TimeInterval,
        isVideo: Bool,
        session: MusicLibraryMetadataSession
    ) async -> MediaMetadataEmbeddedValues? {
        guard isVideo == false, let mp4Metadata else { return nil }

        let hints = MusicLibraryMatchHints(
            sortTitle: mp4Metadata.values.title,
            sortArtist: mp4Metadata.values.artist,
            sortAlbum: mp4Metadata.values.album,
            duration: duration
        )
        switch await session.lookup(url: url, hints: hints) {
        case let .found(values):
            return values
        case .notFound:
            return nil
        case let .failed(message):
            if didReportMusicLibraryAccessFailure == false {
                lastImportErrors.append(
                    L10n.format(
                        "Music library metadata could not be read; embedded metadata was used instead: %@",
                        message
                    )
                )
                didReportMusicLibraryAccessFailure = true
            }
            return nil
        }
    }

    private nonisolated func copyIntoMediaDirectory(_ sourceURL: URL, id: UUID) async throws -> URL {
        let destination = mediaDirectoryURL(for: sourceURL, id: id)

        return try await Task.detached(priority: .utility) {
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        }.value
    }

    nonisolated func mediaDirectoryURL() -> URL {
        if let mediaDirectoryOverride {
            return mediaDirectoryOverride
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SimpleMediaPlayer", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
    }

    nonisolated func mediaDirectoryURL(for sourceURL: URL, id: UUID) -> URL {
        mediaDirectoryURL().appendingPathComponent(id.uuidString).appendingPathExtension(sourceURL.pathExtension)
    }
}

private struct ImportSources {
    let duration: TimeInterval
    let isVideo: Bool
    let extended: ExtendedAudioSource.Info?
    let metadata: [AVMetadataItem]
    let mp4: MP4MetadataReadResult?
    let music: MediaMetadataEmbeddedValues?
    let id3: MediaMetadataEmbeddedValues?
    let additional: AudioTagReadResult?
}

private struct ImportValues {
    let values: MediaMetadataEmbeddedValues
    let lyrics: String?
    let artwork: Data?
}

extension LibraryService: MediaURLResolving {}

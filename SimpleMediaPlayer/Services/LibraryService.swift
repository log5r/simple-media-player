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

    var failedCount: Int {
        failures.count
    }
}

@MainActor
@Observable
final class LibraryService {
    @ObservationIgnored nonisolated private let mediaDirectoryOverride: URL?
    @ObservationIgnored private let artworkProcessor: ArtworkProcessor
    @ObservationIgnored private let lyricsReader: EmbeddedLyricsReader
    @ObservationIgnored private var lyricsLoadRequests: [UUID: UUID] = [:]
    @ObservationIgnored private var editedLyricsItemIDs: Set<UUID> = []
    @ObservationIgnored private var importTask: (id: UUID, task: Task<Void, Never>)?

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
    private var didReportMusicLibraryAccessFailure = false

    private static let lyricsKeyNeedles = ["lyrics", "ult", "uslt", "sylt", "©lyr", "lyr"]
    private static let compilationKeyNeedles = ["compilation", "cpil", "tcmp", "tcp"]

    private static func firstNonblank(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    init(
        mediaDirectoryURL: URL? = nil,
        artworkProcessor: ArtworkProcessor = ArtworkProcessor(),
        lyricsReader: EmbeddedLyricsReader = EmbeddedLyricsReader()
    ) {
        mediaDirectoryOverride = mediaDirectoryURL
        self.artworkProcessor = artworkProcessor
        self.lyricsReader = lyricsReader
    }

    func importFiles(from urls: [URL], into context: ModelContext, existingItems: [MediaItem]) async {
        guard urls.isEmpty == false else { return }

        let previousTask = importTask?.task
        let requestID = UUID()
        let task = Task { @MainActor in
            await previousTask?.value
            await self.performImport(from: urls, into: context, existingItems: existingItems)
        }
        importTask = (requestID, task)
        await task.value
        if importTask?.id == requestID { importTask = nil }
    }

    private func performImport(from urls: [URL], into context: ModelContext, existingItems: [MediaItem]) async {
        isImporting = true
        importProgress = 0
        importCompletedFileCount = 0
        importTotalFileCount = urls.count
        currentImportFileName = nil
        lastImportErrors = []
        didReportMusicLibraryAccessFailure = false
        defer {
            isImporting = false
            importProgress = 1
            importCompletedFileCount = importTotalFileCount
            currentImportFileName = nil
        }

        var itemsByID: [UUID: MediaItem] = [:]
        do {
            for item in existingItems { itemsByID[item.id] = item }
            for item in try context.fetch(FetchDescriptor<MediaItem>()) { itemsByID[item.id] = item }
        } catch {
            lastImportErrors.append(error.localizedDescription)
            return
        }
        var itemsByFingerprint: [String: [MediaItem]] = [:]
        for item in itemsByID.values {
            if let fingerprint = item.importFingerprint {
                itemsByFingerprint[fingerprint, default: []].append(item)
            }
        }
        let legacyItems = itemsByID.values.filter { $0.importFingerprint == nil }
        var legacyItemsBySize: [UInt64: [MediaItem]]?

        for (index, url) in urls.enumerated() {
            currentImportFileName = url.lastPathComponent
            importProgress = Double(index) / Double(urls.count)
            await Task.yield()

            do {
                let fingerprint = try await importFingerprint(for: url)
                var isDuplicate = await hasAvailableFile(for: itemsByFingerprint[fingerprint] ?? [])
                if isDuplicate == false, legacyItems.isEmpty == false {
                    if legacyItemsBySize == nil {
                        legacyItemsBySize = await groupImportCandidatesBySize(legacyItems)
                    }
                    let size = try await Task.detached(priority: .utility) {
                        try MediaImportFingerprint.fileSize(of: url)
                    }.value
                    for candidate in legacyItemsBySize?[size] ?? [] where candidate.importFingerprint == nil {
                        guard let candidateURL = resolvedURL(for: candidate),
                              let candidateFingerprint = try? await importFingerprint(for: candidateURL)
                        else { continue }
                        candidate.importFingerprint = candidateFingerprint
                        itemsByFingerprint[candidateFingerprint, default: []].append(candidate)
                        if candidateFingerprint == fingerprint {
                            isDuplicate = true
                            break
                        }
                    }
                }
                if isDuplicate == false {
                    let item = try await makeMediaItem(from: url, importFingerprint: fingerprint)
                    context.insert(item)
                    itemsByFingerprint[fingerprint, default: []].append(item)
                }
            } catch {
                lastImportErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            importCompletedFileCount = index + 1
            importProgress = Double(index + 1) / Double(urls.count)
        }

        do {
            try context.save()
        } catch {
            lastImportErrors.append(L10n.format("Could not save: %@", error.localizedDescription))
        }
    }

    func resolvedURL(for item: MediaItem) -> URL? {
        var stale = false
        do {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            return try URL(
                resolvingBookmarkData: item.bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            return fallbackMediaURL(forFileName: item.fileName)
        }
    }

    func loadMediaInfo(for item: MediaItem) async -> MediaInfoDetails {
        let snapshot = MediaInfoItemSnapshot(item: item)
        guard let url = resolvedURL(for: item) else {
            return MediaInfoInspector.missingFileDetails(for: snapshot)
        }

        return await MediaInfoInspector.loadDetails(for: snapshot, url: url)
    }

    func canEditEmbeddedMetadata(for item: MediaItem) -> Bool {
        guard let url = resolvedURL(for: item) else { return false }
        return ID3TagWriter.canWriteMetadata(to: url)
            || MP4MetadataWriter.canWriteMetadata(to: url)
            || AIFFMetadataWriter.canWriteMetadata(to: url)
            || AdditionalAudioMetadata.canWrite(to: url)
    }

    func saveLyrics(_ lyrics: String, for item: MediaItem, embedInFile: Bool, in context: ModelContext) async throws {
        // A delayed read must not restore lyrics that the user has just removed.
        lyricsLoadRequests[item.id] = nil
        let normalizedLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : lyrics

        if embedInFile {
            guard let url = resolvedURL(for: item) else {
                throw MediaMetadataEditError.cannotResolveFile
            }
            let canWriteMetadata = ID3TagWriter.canWriteMetadata(to: url)
                || MP4MetadataWriter.canWriteMetadata(to: url)
                || AIFFMetadataWriter.canWriteMetadata(to: url)
                || AdditionalAudioMetadata.canWrite(to: url)
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

        let previousLyrics = item.lyricsRaw
        item.lyricsRaw = normalizedLyrics
        do {
            try context.save()
            editedLyricsItemIDs.insert(item.id)
        } catch {
            item.lyricsRaw = previousLyrics
            throw error
        }
    }

    func editableMetadataDraft(for item: MediaItem) async -> MediaMetadataEditDraft {
        var draft = MediaMetadataEditDraft(item: item)
        guard let url = resolvedURL(for: item) else { return draft }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let metadata = await allMetadata(for: AVURLAsset(url: url))
        let metadataValues = await metadata.embeddedValues(compilationKeyNeedles: Self.compilationKeyNeedles)
        draft = draft.applying(metadataValues)

        if let mp4Metadata = await mp4Metadata(for: url) {
            draft = draft.applying(mp4Metadata.values)
            if item.isVideo == false {
                let hints = MusicLibraryMatchHints(
                    sortTitle: mp4Metadata.values.title,
                    sortArtist: mp4Metadata.values.artist,
                    sortAlbum: mp4Metadata.values.album,
                    duration: item.duration
                )
                if case let .found(musicLibraryValues) = await MusicLibraryMetadataProvider.lookup(
                    url: url,
                    hints: hints
                ) {
                    draft = draft.applying(musicLibraryValues)
                }
            }
            if let embeddedArtwork = mp4Metadata.artworkData,
               let artworkData = await artworkProcessor.thumbnail(from: embeddedArtwork) {
                draft.artworkData = artworkData
            }
        }

        if ID3TagWriter.canWriteMetadata(to: url),
           let values = try? await Task.detached(priority: .utility, operation: {
               try ID3TagWriter.readMetadata(from: url)
           }).value {
            draft = draft.applying(values)
        }

        if AdditionalAudioMetadata.canWrite(to: url),
           let embedded = try? await Task.detached(priority: .utility, operation: {
               try AdditionalAudioMetadata.read(from: url)
           }).value {
            draft = draft.applying(embedded.values)
            if let artwork = embedded.artworkData { draft.artworkData = artwork }
            if let lyrics = embedded.lyrics { draft.lyrics = lyrics }
        }

        return draft
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
        guard let url = resolvedURL(for: item) else {
            if draft.editsArtwork {
                item.artworkData = draft.artworkData
                try context.save()
                return
            }
            throw MediaMetadataEditError.cannotResolveFile
        }
        let canWriteMetadata = ID3TagWriter.canWriteMetadata(to: url)
            || MP4MetadataWriter.canWriteMetadata(to: url)
            || AIFFMetadataWriter.canWriteMetadata(to: url)
            || AdditionalAudioMetadata.canWrite(to: url)
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

        let modelValues = draft.normalizedModelValues(fileURL: url)
        if canWriteMetadata {
            item.title = modelValues.title
            item.artist = modelValues.artist
            item.album = modelValues.album
            item.genre = modelValues.genre
            item.year = modelValues.year
            item.trackNumber = modelValues.trackNumber
            item.comment = modelValues.comment
            item.albumArtist = modelValues.albumArtist
            item.composer = modelValues.composer
            item.discNumber = modelValues.discNumber
            item.isCompilation = modelValues.isCompilation
        }
        if draft.editsArtwork {
            item.artworkData = draft.artworkData
        }
        if draft.editsLyrics {
            item.lyricsRaw = draft.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.lyrics
        }
        try context.save()
    }

    func updateEmbeddedMetadata(
        for items: [MediaItem],
        patch: MediaMetadataEditPatch,
        in context: ModelContext
    ) async -> BulkMetadataEditResult {
        guard patch.isEmpty == false else {
            return BulkMetadataEditResult(updatedCount: 0, failures: [])
        }

        var updatedCount = 0
        var failures: [BulkMetadataEditFailure] = []

        for item in items {
            do {
                let currentDraft = await editableMetadataDraft(for: item)
                let patchedDraft = patch.applying(to: currentDraft)
                try await updateEmbeddedMetadata(for: item, draft: patchedDraft, in: context)
                updatedCount += 1
            } catch {
                failures.append(BulkMetadataEditFailure(fileName: item.fileName, message: error.localizedDescription))
            }
        }

        return BulkMetadataEditResult(updatedCount: updatedCount, failures: failures)
    }

    nonisolated func fallbackMediaURL(forFileName fileName: String) -> URL {
        mediaDirectoryURL().appendingPathComponent(fileName)
    }

    func delete(_ item: MediaItem, from context: ModelContext) {
        if let url = resolvedURL(for: item) {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(item)
        try? context.save()
    }

    func registerTransformedCopy(
        of source: MediaItem,
        renderedFileURL: URL,
        title: String,
        duration: TimeInterval,
        in context: ModelContext
    ) async throws -> MediaItem {
        try Task.checkCancellation()
        let id = UUID()
        let copiedURL = try await copyTransformedFileIntoMediaDirectory(renderedFileURL, id: id)
        var didRegister = false
        defer {
            if didRegister == false { try? FileManager.default.removeItem(at: copiedURL) }
        }
        try Task.checkCancellation()
        #if os(macOS)
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = try copiedURL.bookmarkData(
            options: bookmarkOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let item = MediaItem(
            id: id,
            title: title,
            artist: source.artist,
            album: source.album,
            genre: source.genre,
            year: source.year,
            trackNumber: source.trackNumber,
            comment: source.comment,
            albumArtist: source.albumArtist,
            composer: source.composer,
            discNumber: source.discNumber,
            isCompilation: source.isCompilation,
            duration: duration.isFinite ? duration : 0,
            isVideo: false,
            lyricsRaw: source.lyricsRaw,
            bookmarkData: bookmark,
            artworkData: source.artworkData,
            fileName: copiedURL.lastPathComponent
        )
        try Task.checkCancellation()
        context.insert(item)
        do {
            try context.save()
        } catch {
            context.delete(item)
            throw error
        }
        didRegister = true
        return item
    }

    private nonisolated func copyTransformedFileIntoMediaDirectory(_ sourceURL: URL, id: UUID) async throws -> URL {
        let destination = mediaDirectoryURL(for: sourceURL, id: id)
        let copyTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = try FileHandle(forReadingFrom: sourceURL)
            defer { try? source.close() }
            let size = try source.seekToEnd()
            guard manager.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            var didCopy = false
            defer {
                if didCopy == false { try? manager.removeItem(at: destination) }
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try MediaFileRewriter.copy(from: source, range: 0..<size, to: output)
            try output.close()
            try Task.checkCancellation()
            didCopy = true
            return destination
        }
        return try await withTaskCancellationHandler {
            try await copyTask.value
        } onCancel: {
            copyTask.cancel()
        }
    }

    private func makeMediaItem(from sourceURL: URL, importFingerprint: String) async throws -> MediaItem {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        let metadata = await allMetadata(for: asset)
        let isVideo = isVideoFile(sourceURL)
        let mp4Metadata = await mp4Metadata(for: sourceURL)
        let musicLibraryMetadata = await musicLibraryMetadata(
            for: sourceURL,
            mp4Metadata: mp4Metadata,
            duration: duration,
            isVideo: isVideo
        )
        var id3Values: MediaMetadataEmbeddedValues?
        if ID3TagWriter.canWriteMetadata(to: sourceURL) {
            id3Values = try? await Task.detached(priority: .utility, operation: {
                try ID3TagWriter.readMetadata(from: sourceURL)
            }).value
        }
        let additionalMetadata: AudioTagReadResult?
        if AdditionalAudioMetadata.canWrite(to: sourceURL) {
            do {
                additionalMetadata = try await Task.detached(priority: .utility) {
                    try AdditionalAudioMetadata.read(from: sourceURL)
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                additionalMetadata = nil
            }
        } else {
            additionalMetadata = nil
        }
        let metadataTitle = await metadata.stringValue(for: .commonIdentifierTitle)
        let metadataArtist = await metadata.stringValue(for: .commonIdentifierArtist)
        let metadataAlbum = await metadata.stringValue(for: .commonIdentifierAlbumName)
        let metadataGenre = await metadata.firstString(whereKeyContains: ["genre", "gnre", "tco"])
        let metadataYear = await metadata.firstDisplayString(
            whereKeyContains: ["year", "date", "tdrc", "tyer", "tye", "©day"]
        )
        let metadataTrackNumber = await metadata.firstDisplayString(
            whereKeyContains: ["track number", "tracknumber", "trck", "trk", "trkn"]
        )
        let metadataComment = await metadata.firstDisplayString(whereKeyContains: ["comment", "comm", "©cmt"])
        let metadataAlbumArtist = await metadata.firstDisplayString(
            whereKeyContains: ["album artist", "albumartist", "tpe2", "tp2", "aART"]
        )
        let metadataComposer = await metadata.firstDisplayString(whereKeyContains: ["composer", "tcom", "tcm", "©wrt"])
        let metadataDiscNumber = await metadata.firstDisplayString(
            whereKeyContains: ["disc number", "discnumber", "disk", "tpos", "tpa"]
        )
        let metadataIsCompilation = await metadata.firstBool(whereKeyContains: Self.compilationKeyNeedles)

        let title = Self.firstNonblank(
            additionalMetadata?.values.title,
            id3Values?.title,
            musicLibraryMetadata?.title,
            mp4Metadata?.values.title,
            metadataTitle
        )
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let artist = Self.firstNonblank(
            additionalMetadata?.values.artist,
            id3Values?.artist,
            musicLibraryMetadata?.artist,
            mp4Metadata?.values.artist,
            metadataArtist
        )
            ?? "Unknown Artist"
        let album = Self.firstNonblank(
            additionalMetadata?.values.album,
            id3Values?.album,
            musicLibraryMetadata?.album,
            mp4Metadata?.values.album,
            metadataAlbum
        )
            ?? "Unknown Album"
        let genre = Self.firstNonblank(
            additionalMetadata?.values.genre, id3Values?.genre, musicLibraryMetadata?.genre,
            mp4Metadata?.values.genre, metadataGenre
        )
        let year = Self.firstNonblank(
            additionalMetadata?.values.year, id3Values?.year, musicLibraryMetadata?.year,
            mp4Metadata?.values.year, metadataYear
        )
        let trackNumber = Self.firstNonblank(
            additionalMetadata?.values.trackNumber, id3Values?.trackNumber, musicLibraryMetadata?.trackNumber,
            mp4Metadata?.values.trackNumber, metadataTrackNumber
        )
        let comment = Self.firstNonblank(
            additionalMetadata?.values.comment, id3Values?.comment, musicLibraryMetadata?.comment,
            mp4Metadata?.values.comment, metadataComment
        )
        let albumArtist = Self.firstNonblank(
            additionalMetadata?.values.albumArtist, id3Values?.albumArtist, musicLibraryMetadata?.albumArtist,
            mp4Metadata?.values.albumArtist, metadataAlbumArtist
        )
        let composer = Self.firstNonblank(
            additionalMetadata?.values.composer, id3Values?.composer, musicLibraryMetadata?.composer,
            mp4Metadata?.values.composer, metadataComposer
        )
        let discNumber = Self.firstNonblank(
            additionalMetadata?.values.discNumber, id3Values?.discNumber, musicLibraryMetadata?.discNumber,
            mp4Metadata?.values.discNumber, metadataDiscNumber
        )
        let isCompilation = additionalMetadata?.values.isCompilation ?? id3Values?.isCompilation
            ?? musicLibraryMetadata?.isCompilation
            ?? mp4Metadata?.values.isCompilation
            ?? metadataIsCompilation
            ?? false
        let metadataLyrics = await metadata.firstString(whereKeyContains: Self.lyricsKeyNeedles)
        let lyricsRaw = isVideo ? nil : additionalMetadata?.lyrics ?? mp4Metadata?.lyrics ?? metadataLyrics
        let metadataArtwork = await metadata.dataValue(for: .commonIdentifierArtwork)
        let embeddedArtwork = additionalMetadata?.artworkData ?? mp4Metadata?.artworkData ?? metadataArtwork
        var artwork: Data?
        if let embeddedArtwork {
            artwork = await artworkProcessor.thumbnail(from: embeddedArtwork)
        }

        let id = UUID()
        let copiedURL = try await copyIntoMediaDirectory(sourceURL, id: id)
        var didCreateItem = false
        defer {
            if didCreateItem == false { try? FileManager.default.removeItem(at: copiedURL) }
        }
        #if os(macOS)
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = try copiedURL.bookmarkData(
            options: bookmarkOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let item = MediaItem(
            id: id,
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            comment: comment,
            albumArtist: albumArtist,
            composer: composer,
            discNumber: discNumber,
            isCompilation: isCompilation,
            duration: duration.isFinite ? duration : 0,
            isVideo: isVideo,
            lyricsRaw: lyricsRaw,
            bookmarkData: bookmark,
            artworkData: artwork,
            fileName: copiedURL.lastPathComponent,
            importFingerprint: importFingerprint
        )
        didCreateItem = true
        return item
    }

    private func importFingerprint(for url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try MediaImportFingerprint.read(from: url)
        }.value
    }

    private func hasAvailableFile(for items: [MediaItem]) async -> Bool {
        guard items.isEmpty == false else { return false }
        let urls = items.compactMap { resolvedURL(for: $0) }
        return await Task.detached(priority: .utility) {
            urls.contains { (try? MediaImportFingerprint.fileSize(of: $0)) != nil }
        }.value
    }

    private func groupImportCandidatesBySize(_ items: [MediaItem]) async -> [UInt64: [MediaItem]] {
        let candidates = items.compactMap { item -> (UUID, URL)? in
            guard let url = resolvedURL(for: item) else { return nil }
            return (item.id, url)
        }
        let sizes = await Task.detached(priority: .utility) {
            var sizes: [UUID: UInt64] = [:]
            for (id, url) in candidates {
                sizes[id] = try? MediaImportFingerprint.fileSize(of: url)
            }
            return sizes
        }.value
        var grouped: [UInt64: [MediaItem]] = [:]
        for item in items {
            if let size = sizes[item.id] { grouped[size, default: []].append(item) }
        }
        return grouped
    }

    func refreshMissingLyrics(for item: MediaItem, in context: ModelContext) async {
        guard Task.isCancelled == false,
              item.isVideo == false,
              editedLyricsItemIDs.contains(item.id) == false,
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
              editedLyricsItemIDs.contains(itemID) == false,
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
        var metadata = (try? await asset.load(.metadata)) ?? []
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
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
        isVideo: Bool
    ) async -> MediaMetadataEmbeddedValues? {
        guard isVideo == false, let mp4Metadata else { return nil }

        let hints = MusicLibraryMatchHints(
            sortTitle: mp4Metadata.values.title,
            sortArtist: mp4Metadata.values.artist,
            sortAlbum: mp4Metadata.values.album,
            duration: duration
        )
        switch await MusicLibraryMetadataProvider.lookup(url: url, hints: hints) {
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

extension LibraryService: MediaURLResolving {}

private extension Array where Element == AVMetadataItem {
    func stringValue(for identifier: AVMetadataIdentifier) async -> String? {
        for item in AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier) {
            if let string = try? await item.load(.stringValue), string.isEmpty == false {
                return string
            }
        }
        return nil
    }

    func dataValue(for identifier: AVMetadataIdentifier) async -> Data? {
        for item in AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier) {
            if let data = try? await item.load(.dataValue) {
                return data
            }
        }
        return nil
    }

    func firstString(whereKeyContains needles: [String]) async -> String? {
        for item in self where item.matchesKeyNeedles(needles) {
            if let string = try? await item.load(.stringValue), string.isEmpty == false {
                return string
            }
        }
        return nil
    }

    func firstDisplayString(whereKeyContains needles: [String]) async -> String? {
        for item in self where item.matchesKeyNeedles(needles) {
            if let string = try? await item.load(.stringValue), string.isEmpty == false {
                return string
            }
            if let number = try? await item.load(.numberValue) {
                return number.stringValue
            }
            if let value = try? await item.load(.value),
               let string = Self.displayString(value),
               string.isEmpty == false {
                return string
            }
        }
        return nil
    }

    func firstBool(whereKeyContains needles: [String]) async -> Bool? {
        for item in self where item.matchesKeyNeedles(needles) {
            if let number = try? await item.load(.numberValue) {
                return number.boolValue
            }
            if let string = try? await item.load(.stringValue) {
                let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["1", "true", "yes"].contains(normalized) { return true }
                if ["0", "false", "no"].contains(normalized) { return false }
            }
            if let data = try? await item.load(.dataValue), let byte = data.last {
                return byte != 0
            }
        }
        return nil
    }

    static func displayString(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let number as NSNumber:
            return number.stringValue
        case let data as Data:
            return mp4NumberPairString(data)
        default:
            return nil
        }
    }

    static func mp4NumberPairString(_ data: Data) -> String? {
        let payload = data.count >= 8 ? Data(data.suffix(8)) : data
        guard payload.count >= 6 else { return nil }
        let start = payload.startIndex
        let current = UInt16(payload[start + 2]) << 8 | UInt16(payload[start + 3])
        let total = UInt16(payload[start + 4]) << 8 | UInt16(payload[start + 5])
        guard current > 0 else { return nil }
        return total > 0 ? "\(current)/\(total)" : "\(current)"
    }

    func embeddedValues(compilationKeyNeedles: [String]) async -> MediaMetadataEmbeddedValues {
        MediaMetadataEmbeddedValues(
            title: await stringValue(for: .commonIdentifierTitle),
            artist: await stringValue(for: .commonIdentifierArtist),
            album: await stringValue(for: .commonIdentifierAlbumName),
            genre: await firstString(whereKeyContains: ["genre", "gnre", "tco"]),
            year: await firstDisplayString(whereKeyContains: ["year", "date", "tdrc", "tyer", "tye", "©day"]),
            trackNumber: await firstDisplayString(
                whereKeyContains: ["track number", "tracknumber", "trck", "trk", "trkn"]
            ),
            comment: await firstDisplayString(whereKeyContains: ["comment", "comm", "©cmt"]),
            albumArtist: await firstDisplayString(
                whereKeyContains: ["album artist", "albumartist", "tpe2", "tp2", "aART"]
            ),
            composer: await firstDisplayString(whereKeyContains: ["composer", "tcom", "tcm", "©wrt"]),
            discNumber: await firstDisplayString(
                whereKeyContains: ["disc number", "discnumber", "disk", "tpos", "tpa"]
            ),
            isCompilation: await firstBool(whereKeyContains: compilationKeyNeedles)
        )
    }
}

private extension AVMetadataItem {
    func matchesKeyNeedles(_ needles: [String]) -> Bool {
        let haystacks = [
            identifier?.rawValue,
            commonKey?.rawValue,
            key as? String
        ].compactMap { $0?.lowercased() }

        return haystacks.contains { value in
            needles.contains { value.contains($0.lowercased()) }
        }
    }
}

private enum MediaInfoInspector {
    static func missingFileDetails(for item: MediaInfoItemSnapshot) -> MediaInfoDetails {
        MediaInfoDetails(
            fileRows: [
                MediaInfoRow(id: "fileName", label: L10n.string("File"), value: item.fileName)
            ],
            summaryRows: summaryRows(for: item),
            sections: [],
            errorMessage: L10n.string("Could not resolve the media file.")
        )
    }

    static func loadDetails(for item: MediaInfoItemSnapshot, url: URL) async -> MediaInfoDetails {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let fileRows = fileRows(for: item, url: url)
        let asset = AVURLAsset(url: url)

        do {
            async let summaryRows = assetSummaryRows(for: item, asset: asset)
            async let metadataSections = metadataSections(for: asset)
            async let trackSections = trackSections(for: asset)

            return MediaInfoDetails(
                fileRows: fileRows,
                summaryRows: await summaryRows,
                sections: try await metadataSections + trackSections,
                errorMessage: nil
            )
        } catch {
            return MediaInfoDetails(
                fileRows: fileRows,
                summaryRows: summaryRows(for: item),
                sections: [],
                errorMessage: L10n.format("Could not read media info: %@", error.localizedDescription)
            )
        }
    }

    private static func fileRows(for item: MediaInfoItemSnapshot, url: URL) -> [MediaInfoRow] {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .totalFileSizeKey,
            .contentTypeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let byteCount = values?.totalFileSize ?? values?.fileSize

        var rows = [
            MediaInfoRow(id: "fileName", label: L10n.string("File"), value: item.fileName),
            MediaInfoRow(id: "filePath", label: L10n.string("File Path"), value: url.path)
        ]

        if let byteCount, byteCount >= 0 {
            rows.append(MediaInfoRow(
                id: "fileSize",
                label: L10n.string("File Size"),
                value: "\(MediaInfoTextFormatter.fileSize(bytes: Int64(byteCount))) (\(byteCount) bytes)"
            ))
        }
        if let type = values?.contentType {
            rows.append(MediaInfoRow(id: "contentType", label: L10n.string("Content Type"), value: type.identifier))
        }
        if let creationDate = values?.creationDate {
            rows.append(MediaInfoRow(
                id: "created",
                label: L10n.string("Created"),
                value: creationDate.formatted(date: .numeric, time: .shortened)
            ))
        }
        if let modifiedDate = values?.contentModificationDate {
            rows.append(MediaInfoRow(
                id: "modified",
                label: L10n.string("Modified"),
                value: modifiedDate.formatted(date: .numeric, time: .shortened)
            ))
        }

        return rows
    }

    private static func summaryRows(for item: MediaInfoItemSnapshot) -> [MediaInfoRow] {
        var rows = [
            MediaInfoRow(id: "title", label: L10n.string("Title"), value: item.title),
            MediaInfoRow(id: "artist", label: L10n.string("Artist"), value: item.displayArtist),
            MediaInfoRow(id: "album", label: L10n.string("Album"), value: item.displayAlbum),
            MediaInfoRow(id: "genre", label: L10n.string("Genre"), value: item.displayGenre),
            MediaInfoRow(id: "duration", label: L10n.string("Time"), value: item.duration.mediaTime),
            MediaInfoRow(
                id: "kind",
                label: L10n.string("Kind"),
                value: item.isVideo ? L10n.string("Video") : L10n.string("Audio")
            ),
            MediaInfoRow(
                id: "added",
                label: L10n.string("Date Added"),
                value: item.addedAt.formatted(date: .numeric, time: .shortened)
            )
        ]
        appendOptionalRow(id: "year", label: L10n.string("Year"), value: item.year, to: &rows)
        appendOptionalRow(id: "trackNumber", label: L10n.string("Track"), value: item.trackNumber, to: &rows)
        appendOptionalRow(id: "albumArtist", label: L10n.string("Album Artist"), value: item.albumArtist, to: &rows)
        appendOptionalRow(id: "composer", label: L10n.string("Composer"), value: item.composer, to: &rows)
        appendOptionalRow(id: "discNumber", label: L10n.string("Disc Number"), value: item.discNumber, to: &rows)
        if item.isCompilation {
            rows.append(MediaInfoRow(id: "compilation", label: L10n.string("Compilation"), value: yesNo(true)))
        }
        appendOptionalRow(id: "comment", label: L10n.string("Comment"), value: item.comment, to: &rows)
        return rows
    }

    private static func appendOptionalRow(id: String, label: String, value: String?, to rows: inout [MediaInfoRow]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else { return }
        rows.append(MediaInfoRow(id: id, label: label, value: value))
    }

    private static func assetSummaryRows(for item: MediaInfoItemSnapshot, asset: AVURLAsset) async -> [MediaInfoRow] {
        var rows = summaryRows(for: item)

        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 {
            rows.append(MediaInfoRow(
                id: "assetDuration",
                label: L10n.string("Asset Duration"),
                value: duration.mediaTime
            ))
        }
        if let isPlayable = try? await asset.load(.isPlayable) {
            rows.append(MediaInfoRow(id: "isPlayable", label: L10n.string("Playable"), value: yesNo(isPlayable)))
        }
        if let isReadable = try? await asset.load(.isReadable) {
            rows.append(MediaInfoRow(id: "isReadable", label: L10n.string("Readable"), value: yesNo(isReadable)))
        }
        if let isExportable = try? await asset.load(.isExportable) {
            rows.append(MediaInfoRow(id: "isExportable", label: L10n.string("Exportable"), value: yesNo(isExportable)))
        }
        if let isComposable = try? await asset.load(.isComposable) {
            rows.append(MediaInfoRow(id: "isComposable", label: L10n.string("Composable"), value: yesNo(isComposable)))
        }
        if let hasProtectedContent = try? await asset.load(.hasProtectedContent) {
            rows.append(MediaInfoRow(
                id: "protected",
                label: L10n.string("Protected Content"),
                value: yesNo(hasProtectedContent)
            ))
        }
        if let containsFragments = try? await asset.load(.containsFragments) {
            rows.append(MediaInfoRow(
                id: "fragments",
                label: L10n.string("Contains Fragments"),
                value: yesNo(containsFragments)
            ))
        }
        if let preciseTiming = try? await asset.load(.providesPreciseDurationAndTiming) {
            rows.append(MediaInfoRow(
                id: "preciseTiming",
                label: L10n.string("Precise Timing"),
                value: yesNo(preciseTiming)
            ))
        }
        if let preferredRate = try? await asset.load(.preferredRate), preferredRate > 0 {
            rows.append(MediaInfoRow(
                id: "preferredRate",
                label: L10n.string("Preferred Rate"),
                value: MediaInfoTextFormatter.compactDecimal(Double(preferredRate))
            ))
        }
        if let preferredVolume = try? await asset.load(.preferredVolume), preferredVolume >= 0 {
            rows.append(MediaInfoRow(
                id: "preferredVolume",
                label: L10n.string("Preferred Volume"),
                value: MediaInfoTextFormatter.compactDecimal(Double(preferredVolume))
            ))
        }

        return rows
    }

    private static func metadataSections(for asset: AVURLAsset) async throws -> [MediaInfoSection] {
        var sections: [MediaInfoSection] = []
        let commonMetadata = try await asset.load(.metadata)
        if commonMetadata.isEmpty == false {
            sections.append(MediaInfoSection(
                id: "metadata-common",
                title: L10n.string("Common Metadata"),
                rows: await metadataRows(for: commonMetadata, idPrefix: "common")
            ))
        }

        let formats = try await asset.load(.availableMetadataFormats)
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            guard items.isEmpty == false else { continue }
            sections.append(MediaInfoSection(
                id: "metadata-\(format.rawValue)",
                title: metadataFormatTitle(format),
                rows: await metadataRows(for: items, idPrefix: format.rawValue)
            ))
        }

        if sections.isEmpty {
            sections.append(MediaInfoSection(
                id: "metadata-empty",
                title: L10n.string("Embedded Metadata"),
                rows: [MediaInfoRow(
                    id: "metadata-empty-row",
                    label: L10n.string("Metadata"),
                    value: L10n.string("No embedded metadata")
                )]
            ))
        }

        return sections
    }

    private static func metadataRows(for items: [AVMetadataItem], idPrefix: String) async -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []

        for (index, item) in items.enumerated() {
            let label = metadataLabel(for: item, fallback: "\(L10n.string("Item")) \(index + 1)")
            var details: [String] = []

            details.append(await metadataValue(for: item))
            appendDetail(L10n.string("Identifier"), item.identifier?.rawValue, to: &details)
            appendDetail(L10n.string("Common Key"), item.commonKey?.rawValue, to: &details)
            appendDetail(L10n.string("Key Space"), item.keySpace?.rawValue, to: &details)
            appendDetail(L10n.string("Key"), displayValue(item.key), to: &details)
            appendDetail(L10n.string("Data Type"), item.dataType, to: &details)
            appendDetail(L10n.string("Language"), item.extendedLanguageTag ?? item.locale?.identifier, to: &details)

            if item.time.isValid && item.time.seconds.isFinite {
                appendDetail(L10n.string("Time"), item.time.seconds.mediaTime, to: &details)
            }
            if item.duration.isValid && item.duration.seconds.isFinite && item.duration.seconds > 0 {
                appendDetail(L10n.string("Duration"), item.duration.seconds.mediaTime, to: &details)
            }
            if let extraAttributes = try? await item.load(.extraAttributes), extraAttributes.isEmpty == false {
                appendDetail(L10n.string("Extra Attributes"), displayValue(extraAttributes), to: &details)
            }

            rows.append(MediaInfoRow(
                id: "\(idPrefix)-\(index)",
                label: label,
                value: details.filter { $0.isEmpty == false }.joined(separator: "\n")
            ))
        }

        return rows
    }

    private static func trackSections(for asset: AVURLAsset) async throws -> [MediaInfoSection] {
        let tracks = try await asset.load(.tracks)

        return await tracks.enumerated().asyncMap { index, track in
            var rows: [MediaInfoRow] = [
                MediaInfoRow(id: "mediaType", label: L10n.string("Media Type"), value: track.mediaType.rawValue)
            ]

            if let naturalSize = try? await track.load(.naturalSize), naturalSize.width > 0 || naturalSize.height > 0 {
                rows.append(MediaInfoRow(
                    id: "naturalSize",
                    label: L10n.string("Dimensions"),
                    value: "\(Int(naturalSize.width.rounded())) x \(Int(naturalSize.height.rounded()))"
                ))
            }
            if let frameRate = try? await track.load(.nominalFrameRate), frameRate > 0 {
                rows.append(MediaInfoRow(
                    id: "frameRate",
                    label: L10n.string("Frame Rate"),
                    value: "\(MediaInfoTextFormatter.compactDecimal(Double(frameRate))) fps"
                ))
            }
            if let dataRate = try? await track.load(.estimatedDataRate), dataRate > 0 {
                rows.append(MediaInfoRow(
                    id: "dataRate",
                    label: L10n.string("Estimated Data Rate"),
                    value: "\(Int((dataRate / 1000).rounded())) kbps"
                ))
            }
            if let languageCode = try? await track.load(.languageCode), languageCode != "und" {
                rows.append(MediaInfoRow(id: "language", label: L10n.string("Language"), value: languageCode))
            }
            if let extendedLanguageTag = try? await track.load(.extendedLanguageTag) {
                rows.append(MediaInfoRow(
                    id: "extendedLanguage",
                    label: L10n.string("Extended Language"),
                    value: extendedLanguageTag
                ))
            }
            if let formatDescriptions = try? await track.load(.formatDescriptions) {
                rows.append(contentsOf: formatDescriptionRows(formatDescriptions))
            }

            let title = L10n.format("Track %d - %@", index + 1, track.mediaType.rawValue)
            return MediaInfoSection(id: "track-\(index)", title: title, rows: rows)
        }
    }

    private static func formatDescriptionRows(_ descriptions: [CMFormatDescription]) -> [MediaInfoRow] {
        descriptions.enumerated().flatMap { index, description in
            var rows: [MediaInfoRow] = [
                MediaInfoRow(
                    id: "format-\(index)-mediaType",
                    label: L10n.format("Format %d Media Type", index + 1),
                    value: fourCharacterCode(CMFormatDescriptionGetMediaType(description))
                ),
                MediaInfoRow(
                    id: "format-\(index)-subtype",
                    label: L10n.format("Format %d Codec", index + 1),
                    value: fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
                )
            ]

            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            if dimensions.width > 0 || dimensions.height > 0 {
                rows.append(MediaInfoRow(
                    id: "format-\(index)-dimensions",
                    label: L10n.format("Format %d Dimensions", index + 1),
                    value: "\(dimensions.width) x \(dimensions.height)"
                ))
            }

            if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                rows.append(MediaInfoRow(
                    id: "format-\(index)-sampleRate",
                    label: L10n.format("Format %d Sample Rate", index + 1),
                    value: "\(MediaInfoTextFormatter.compactDecimal(streamDescription.mSampleRate)) Hz"
                ))
                rows.append(MediaInfoRow(
                    id: "format-\(index)-channels",
                    label: L10n.format("Format %d Channels", index + 1),
                    value: String(streamDescription.mChannelsPerFrame)
                ))
                if streamDescription.mBitsPerChannel > 0 {
                    rows.append(MediaInfoRow(
                        id: "format-\(index)-bits",
                        label: L10n.format("Format %d Bits per Channel", index + 1),
                        value: String(streamDescription.mBitsPerChannel)
                    ))
                }
            }

            if let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
               extensions.isEmpty == false,
               let formattedExtensions = displayValue(extensions) {
                rows.append(MediaInfoRow(
                    id: "format-\(index)-extensions",
                    label: L10n.format("Format %d Extensions", index + 1),
                    value: formattedExtensions
                ))
            }

            return rows
        }
    }

    private static func metadataLabel(for item: AVMetadataItem, fallback: String) -> String {
        if let commonKey = item.commonKey?.rawValue {
            return commonKey
        }
        if let identifier = item.identifier?.rawValue {
            return identifier
        }
        if let key = displayValue(item.key) {
            return key
        }
        return fallback
    }

    private static func metadataValue(for item: AVMetadataItem) async -> String {
        if let string = try? await item.load(.stringValue), string.isEmpty == false {
            return string
        }
        if let number = try? await item.load(.numberValue) {
            return number.stringValue
        }
        if let date = try? await item.load(.dateValue) {
            return date.formatted(date: .numeric, time: .shortened)
        }
        if let data = try? await item.load(.dataValue) {
            if let text = String(data: data, encoding: .utf8),
               text.trimmingCharacters(in: .controlCharacters).isEmpty == false {
                return text
            }
            return L10n.format("Binary data (%@)", MediaInfoTextFormatter.fileSize(bytes: Int64(data.count)))
        }
        if let value = try? await item.load(.value) {
            return displayValue(value) ?? String(describing: value)
        }
        return L10n.string("No readable value")
    }

    private static func metadataFormatTitle(_ format: AVMetadataFormat) -> String {
        switch format {
        case .id3Metadata:
            return L10n.string("ID3 Metadata")
        case .iTunesMetadata:
            return L10n.string("iTunes Metadata")
        case .quickTimeMetadata:
            return L10n.string("QuickTime Metadata")
        case .quickTimeUserData:
            return L10n.string("QuickTime User Data")
        case .isoUserData:
            return L10n.string("ISO User Data")
        default:
            return format.rawValue
        }
    }

    private static func appendDetail(_ label: String, _ value: String?, to details: inout [String]) {
        guard let value, value.isEmpty == false else { return }
        details.append("\(label): \(value)")
    }

    private static func displayValue(_ value: Any?) -> String? {
        guard let value else { return nil }

        switch value {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let number as NSNumber:
            return number.stringValue
        case let date as Date:
            return date.formatted(date: .numeric, time: .shortened)
        case let data as Data:
            return L10n.format("Binary data (%@)", MediaInfoTextFormatter.fileSize(bytes: Int64(data.count)))
        case let array as [Any]:
            return array.compactMap(displayValue).joined(separator: ", ")
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().compactMap { key in
                guard let value = displayValue(dictionary[key]) else { return nil }
                return "\(key): \(value)"
            }.joined(separator: "\n")
        case let dictionary as NSDictionary:
            return dictionary.allKeys
                .map { String(describing: $0) }
                .sorted()
                .compactMap { key in
                    guard let value = displayValue(dictionary[key]) else { return nil }
                    return "\(key): \(value)"
                }
                .joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let scalars = [
            UnicodeScalar((code >> 24) & 0xFF),
            UnicodeScalar((code >> 16) & 0xFF),
            UnicodeScalar((code >> 8) & 0xFF),
            UnicodeScalar(code & 0xFF)
        ]

        let string = scalars.compactMap { scalar -> Character? in
            guard let scalar, scalar.isASCII, scalar.value >= 32 else { return nil }
            return Character(scalar)
        }

        if string.count == 4 {
            return String(string)
        }
        return "0x\(String(code, radix: 16, uppercase: true))"
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? L10n.string("Yes") : L10n.string("No")
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}

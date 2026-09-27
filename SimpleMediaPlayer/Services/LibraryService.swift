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

        if let kind = try? ExtendedAudioSource.kind(for: url),
           let info = try? ExtendedAudioSource.info(for: url, kind: kind) {
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
}

extension LibraryService {
    nonisolated func fallbackMediaURL(forFileName fileName: String) -> URL {
        mediaDirectoryURL().appendingPathComponent(fileName)
    }

    func delete(_ item: MediaItem, from context: ModelContext) {
        if let url = resolvedURL(for: item) {
            let cacheURL = ExtendedAudioSource.cacheURL(for: url)
            try? FileManager.default.removeItem(at: url)
            if let cacheURL { ExtendedAudioSource.removeCacheInBackground(at: cacheURL) }
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
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        let sources = try await readImportSources(from: sourceURL)
        let importValues = await mergeImportSources(sources, fileURL: sourceURL)
        let values = importValues.values
        let id = UUID()
        let copiedURL = try await copyIntoMediaDirectory(sourceURL, id: id)
        var didCreateItem = false
        defer { if didCreateItem == false { try? FileManager.default.removeItem(at: copiedURL) } }
        if sources.extended != nil {
            let prepareTask = Task.detached(priority: .utility) {
                try ExtendedAudioSource.readableURL(for: copiedURL)
            }
            _ = try await withTaskCancellationHandler {
                try await prepareTask.value
            } onCancel: {
                prepareTask.cancel()
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

    private func readImportSources(from url: URL) async throws -> ImportSources {
        let extendedKind = try ExtendedAudioSource.kind(for: url)
        let extended = try extendedKind.map { try ExtendedAudioSource.info(for: url, kind: $0) }
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
            for: url, mp4Metadata: mp4, duration: duration, isVideo: isVideo
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
        if AdditionalAudioMetadata.canWrite(to: url) {
            do {
                additional = try await Task.detached(priority: .utility) {
                    try AdditionalAudioMetadata.read(from: url)
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                additional = nil
            }
        } else {
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

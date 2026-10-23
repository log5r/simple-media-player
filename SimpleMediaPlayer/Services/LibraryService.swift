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
    @ObservationIgnored let artworkProcessor: ArtworkProcessor
    @ObservationIgnored let artworkLoader: LibraryArtworkLoader
    @ObservationIgnored let lyricsReader: EmbeddedLyricsReader
    @ObservationIgnored let musicMetadataProvider: MusicLibraryMetadataProvider
    @ObservationIgnored let editabilityChecker: EmbeddedMetadataEditabilityChecker
    @ObservationIgnored nonisolated let resolveBookmark: @Sendable (Data, URL) -> URL
    @ObservationIgnored nonisolated let removalJournal: PendingFileRemovalJournal
    @ObservationIgnored let saveContext: @MainActor (ModelContext) throws -> Void
    @ObservationIgnored let beforeMetadataWrite: @Sendable (URL) async throws -> Void
    @ObservationIgnored let metadataWriter: @Sendable (MediaMetadataEditDraft, URL) throws -> Void
    @ObservationIgnored let beforeImportRegistration: @MainActor (URL) async -> Void
    @ObservationIgnored let importRequestStarted: @MainActor () -> Void
    /// Shared by every export plan, so resolutions left running by a cancelled plan still count.
    @ObservationIgnored nonisolated let exportPlanLimiter = FileSystemWorkLimiter(limit: exportPlanConcurrency)
    /// Shared by Music import pre-checks, so probes abandoned by cancelled preparations still count.
    @ObservationIgnored nonisolated let musicLibraryProbeLimiter = FileSystemWorkLimiter(limit: 2)
    @ObservationIgnored var lyricsLoadRequests: [UUID: UUID] = [:]
    @ObservationIgnored var importTask: (id: UUID, task: Task<MediaImportSummary, Never>)?
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
    var didReportMusicLibraryAccessFailure = false

    static let compilationKeyNeedles = ["compilation", "cpil", "tcmp", "tcp"]

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
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
        beforeMetadataWrite: @escaping @Sendable (URL) async throws -> Void = { _ in },
        metadataWriter: @escaping @Sendable (MediaMetadataEditDraft, URL) throws -> Void
            = LibraryService.writeEmbeddedMetadata,
        beforeImportRegistration: @escaping @MainActor (URL) async -> Void = { _ in },
        importRequestStarted: @escaping @MainActor () -> Void = {}
    ) {
        mediaDirectoryOverride = mediaDirectoryURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.resolveBookmark = resolveBookmark
        self.removalJournal = removalJournal
        self.saveContext = saveContext
        self.beforeMetadataWrite = beforeMetadataWrite
        self.metadataWriter = metadataWriter
        self.beforeImportRegistration = beforeImportRegistration
        self.importRequestStarted = importRequestStarted
        self.artworkProcessor = artworkProcessor
        self.lyricsReader = lyricsReader
        self.artworkLoader = artworkLoader
        self.editabilityChecker = editabilityChecker
        self.musicMetadataProvider = musicMetadataProvider
    }
}

extension LibraryService {
    func resolvedURL(for item: MediaItem) -> URL? {
        resolvedURL(for: fileReference(for: item))
    }

    nonisolated func fallbackMediaURL(forFileName fileName: String) -> URL {
        mediaDirectoryURL().appendingPathComponent(fileName)
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

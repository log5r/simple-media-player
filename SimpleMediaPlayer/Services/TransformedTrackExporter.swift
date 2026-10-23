import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TransformedTrackExporter {
    private struct PreparedCopy {
        let snapshot: TransformedTrackSourceSnapshot
        let draft: MediaMetadataEditDraft
    }

    private struct RenderRequest: Sendable {
        let sourceURL: URL
        let outputURL: URL
        let format: TransformedExportFormat
        let pitchSemitones: Int
        let rate: Double
        let draft: MediaMetadataEditDraft
        let exportID: UUID
    }

    private struct ExportRequest {
        let item: MediaItem
        let sourceContext: ModelContext?
        let sourceURL: URL
        let outputURL: URL
        let title: String
        let format: TransformedExportFormat
        let pitchSemitones: Int
        let rate: Double
        let exportID: UUID
        let libraryService: LibraryService
        let context: ModelContext
    }

    private struct ExportSource {
        let context: ModelContext?
        let title: String
        let url: URL
    }

    var isExporting = false
    var progress = 0.0
    var errorMessage: String?

    @ObservationIgnored private let renderer: any TransformedAudioRendering
    @ObservationIgnored private let temporaryDirectory: URL
    @ObservationIgnored private let progressReportInterval: Duration
    @ObservationIgnored private var exportID: UUID?

    init(
        renderer: any TransformedAudioRendering = TransformedAudioRenderer(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        progressReportInterval: Duration = ProgressReportThrottle.defaultMinimumInterval
    ) {
        self.renderer = renderer
        self.temporaryDirectory = temporaryDirectory
        self.progressReportInterval = progressReportInterval
    }

    func export(
        item: MediaItem,
        title: String,
        format: TransformedExportFormat,
        pitchSemitones: Int,
        rate: Double,
        libraryService: LibraryService,
        context: ModelContext
    ) async throws -> MediaItem {
        try Task.checkCancellation()
        let source = try resolveExportSource(
            item: item, title: title, libraryService: libraryService
        )

        isExporting = true
        progress = 0
        errorMessage = nil
        let exportID = UUID()
        self.exportID = exportID
        let outputURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)
        let didAccess = source.url.startAccessingSecurityScopedResource()

        defer {
            if didAccess {
                source.url.stopAccessingSecurityScopedResource()
            }
            try? FileManager.default.removeItem(at: outputURL)
            self.exportID = nil
            isExporting = false
        }

        do {
            return try await performExport(
                ExportRequest(
                    item: item,
                    sourceContext: source.context,
                    sourceURL: source.url,
                    outputURL: outputURL,
                    title: source.title,
                    format: format,
                    pitchSemitones: pitchSemitones,
                    rate: rate,
                    exportID: exportID,
                    libraryService: libraryService,
                    context: context
                )
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                progress = 0
                errorMessage = nil
                throw CancellationError()
            }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func resolveExportSource(
        item: MediaItem, title: String, libraryService: LibraryService
    ) throws -> ExportSource {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            throw TransformedAudioExportError.emptyTitle
        }
        guard let sourceURL = libraryService.resolvedURL(for: item) else {
            throw TransformedAudioExportError.cannotResolveFile
        }
        return ExportSource(context: item.modelContext, title: trimmedTitle, url: sourceURL)
    }

    private func performExport(_ request: ExportRequest) async throws -> MediaItem {
        let prepared = try await prepareCopy(
            item: request.item, title: request.title, libraryService: request.libraryService
        )
        try request.libraryService.validateCopySource(request.item, in: request.sourceContext)
        let renderResult = try await render(
            RenderRequest(
                sourceURL: request.sourceURL,
                outputURL: request.outputURL,
                format: request.format,
                pitchSemitones: request.pitchSemitones,
                rate: request.rate,
                draft: prepared.draft,
                exportID: request.exportID
            )
        )

        try request.libraryService.validateCopySource(request.item, in: request.sourceContext)
        progress = 0.98
        let newItem = try await request.libraryService.registerTransformedCopy(
            of: prepared.snapshot,
            renderedFileURL: request.outputURL,
            title: request.title,
            duration: renderResult.duration,
            in: request.context
        )
        progress = 1
        return newItem
    }

    private func prepareCopy(
        item: MediaItem, title: String, libraryService: LibraryService
    ) async throws -> PreparedCopy {
        // Only the title replaces source text, so untouched placeholder values remain from the source file.
        let textDraft = try await libraryService.itemDraftResolvingPlaceholders(for: item, patching: [.title])
        var snapshot = TransformedTrackSourceSnapshot(item: item)
        let draft = try await metadataDraft(from: textDraft, for: item, title: title, libraryService: libraryService)
        snapshot.artworkData = draft.artworkData
        return PreparedCopy(snapshot: snapshot, draft: draft)
    }

    private func render(_ request: RenderRequest) async throws -> TransformedAudioRenderer.Result {
        let pitchCents = Float(request.pitchSemitones * 100)
        let renderer = renderer
        let reportProgress = makeProgressHandler(for: request.exportID)
        let renderTask = Task.detached(executorPreference: BlockingWorkExecutor.shared, priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try await ExtendedAudioSource.withCancellableCacheWaits {
                try renderer.render(
                    sourceURL: request.sourceURL,
                    pitchCents: pitchCents,
                    rate: Float(request.rate),
                    maxSampleRate: request.format.maxSampleRate,
                    makeEncoder: { processingFormat in
                        if request.format == .mp3 {
                            try MP3Encoder(outputURL: request.outputURL, processingFormat: processingFormat)
                        } else {
                            try CoreAudioFileEncoder(
                                outputURL: request.outputURL,
                                format: request.format,
                                processingFormat: processingFormat
                            )
                        }
                    },
                    progress: reportProgress
                )
            }
            try Task.checkCancellation()
            try request.format.writeMetadata(request.draft, to: request.outputURL)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    /// Offline rendering reports every buffer, far faster than real time, so only visible changes reach the main actor.
    private func makeProgressHandler(for exportID: UUID) -> @Sendable (Double) -> Void {
        let throttle = ProgressReportThrottle(minimumInterval: progressReportInterval)
        return { [weak self] value in
            guard throttle.shouldReport(value) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.exportID == exportID else { return }
                let reportedProgress = max(progress, min(0.95, value * 0.95))
                if reportedProgress != progress {
                    progress = reportedProgress
                }
            }
        }
    }

    private func metadataDraft(
        from textDraft: MediaMetadataEditDraft,
        for item: MediaItem,
        title: String,
        libraryService: LibraryService
    ) async throws -> MediaMetadataEditDraft {
        var draft = textDraft
        draft.artworkData = try await libraryService.libraryArtwork(for: item)
        try Task.checkCancellation()
        draft.title = title
        draft.editsArtwork = true
        draft.editsLyrics = true
        return draft
    }
}

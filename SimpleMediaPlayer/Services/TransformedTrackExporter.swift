import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TransformedTrackExporter {
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
        let sourceContext = item.modelContext
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            throw TransformedAudioExportError.emptyTitle
        }
        guard let sourceURL = libraryService.resolvedURL(for: item) else {
            throw TransformedAudioExportError.cannotResolveFile
        }

        isExporting = true
        progress = 0
        errorMessage = nil
        let exportID = UUID()
        self.exportID = exportID
        let outputURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()

        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            try? FileManager.default.removeItem(at: outputURL)
            self.exportID = nil
            isExporting = false
        }

        var sourceSnapshot = TransformedTrackSourceSnapshot(item: item)
        let pitchCents = Float(pitchSemitones * 100)
        let renderRate = Float(rate)
        let renderer = renderer
        let reportProgress = makeProgressHandler(for: exportID)

        do {
            let draft = try await metadataDraft(for: item, title: trimmedTitle, libraryService: libraryService)
            try libraryService.validateCopySource(item, in: sourceContext)
            sourceSnapshot.artworkData = draft.artworkData
            let renderTask = Task.detached(executorPreference: BlockingWorkExecutor.shared, priority: .userInitiated) {
                try Task.checkCancellation()
                let result = try await ExtendedAudioSource.withCancellableCacheWaits {
                    try renderer.render(
                        sourceURL: sourceURL,
                        pitchCents: pitchCents,
                        rate: renderRate,
                        maxSampleRate: format.maxSampleRate,
                        makeEncoder: { processingFormat in
                            if format == .mp3 {
                                try MP3Encoder(outputURL: outputURL, processingFormat: processingFormat)
                            } else {
                                try CoreAudioFileEncoder(
                                    outputURL: outputURL,
                                    format: format,
                                    processingFormat: processingFormat
                                )
                            }
                        },
                        progress: reportProgress
                    )
                }
                try Task.checkCancellation()
                try format.writeMetadata(draft, to: outputURL)
                try Task.checkCancellation()
                return result
            }
            let renderResult = try await withTaskCancellationHandler {
                try await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }

            try libraryService.validateCopySource(item, in: sourceContext)
            progress = 0.98
            let newItem = try await libraryService.registerTransformedCopy(
                of: sourceSnapshot,
                renderedFileURL: outputURL,
                title: trimmedTitle,
                duration: renderResult.duration,
                in: context
            )
            progress = 1
            return newItem
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
        for item: MediaItem,
        title: String,
        libraryService: LibraryService
    ) async throws -> MediaMetadataEditDraft {
        var draft = MediaMetadataEditDraft(item: item)
        draft.artworkData = try await libraryService.libraryArtwork(for: item)
        try Task.checkCancellation()
        draft.title = title
        draft.editsArtwork = true
        draft.editsLyrics = true
        return draft
    }
}

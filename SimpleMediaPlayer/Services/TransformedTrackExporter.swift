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
    @ObservationIgnored private var exportID: UUID?

    init(
        renderer: any TransformedAudioRendering = TransformedAudioRenderer(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.renderer = renderer
        self.temporaryDirectory = temporaryDirectory
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

        var draft = MediaMetadataEditDraft(item: item)
        draft.title = trimmedTitle
        draft.editsArtwork = true
        draft.editsLyrics = true
        let pitchCents = Float(pitchSemitones * 100)
        let renderRate = Float(rate)
        let renderer = renderer

        do {
            let renderTask = Task.detached(priority: .userInitiated) { [weak self] in
                try Task.checkCancellation()
                let result = try renderer.render(
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
                    progress: { [weak self] value in
                        Task { @MainActor [weak self] in
                            guard let self, self.exportID == exportID else { return }
                            self.progress = max(self.progress, min(0.95, value * 0.95))
                        }
                    }
                )
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

            try Task.checkCancellation()
            progress = 0.98
            let newItem = try await libraryService.registerTransformedCopy(
                of: item,
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
}

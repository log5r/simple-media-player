import AVFoundation
import Foundation
import SwiftData

extension LibraryService {
    func saveLyrics(_ lyrics: String, for item: MediaItem, embedInFile: Bool, in context: ModelContext) async throws {
        // A delayed read must not restore lyrics that the user has just removed.
        lyricsLoadRequests[item.id] = nil
        let normalizedLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : lyrics

        if embedInFile {
            let reference = fileReference(for: item)
            guard let url = resolvedURL(for: item) else {
                throw MediaMetadataEditError.cannotResolveFile
            }
            let canWriteMetadata = try await editabilityChecker.canWriteMetadata(to: url)
            try validateMetadataTarget(reference, item: item, context: context)
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

            let writer = metadataWriter
            try await Task.detached(priority: .utility) {
                try writer(draft, url)
            }.value
            try validateMetadataTarget(reference, item: item, context: context)
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

    func updateEmbeddedMetadata(
        for item: MediaItem,
        draft: MediaMetadataEditDraft,
        in context: ModelContext
    ) async throws {
        let reference = fileReference(for: item)
        guard let url = resolvedURL(for: item) else {
            if draft.editsArtwork {
                item.artworkData = draft.artworkData
                try saveContext(context)
                return
            }
            throw MediaMetadataEditError.cannotResolveFile
        }
        try await beforeMetadataWrite(url)
        try Task.checkCancellation()
        let canWriteMetadata = try await editabilityChecker.canWriteMetadata(to: url)
        try validateMetadataTarget(reference, item: item, context: context)
        guard canWriteMetadata || draft.editsArtwork else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        if canWriteMetadata {
            let writer = metadataWriter
            try await Task.detached(priority: .utility) {
                try writer(draft, url)
            }.value
            try validateMetadataTarget(reference, item: item, context: context)
        }

        applyMetadataValues(draft, to: item, fileURL: url, canWriteMetadata: canWriteMetadata)
        try saveContext(context)
    }

    /// A started file write finishes even after cancellation, but its result belongs only to the captured item.
    private func validateMetadataTarget(
        _ reference: MediaFileReference, item: MediaItem, context: ModelContext
    ) throws {
        guard isLibraryItemLive(item, in: context), item.id == reference.id,
              item.bookmarkData == reference.bookmarkData, item.fileName == reference.fileName else {
            throw CancellationError()
        }
    }

    nonisolated static func writeEmbeddedMetadata(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        if ID3TagWriter.canWriteMetadata(to: url) {
            try ID3TagWriter.write(draft, to: url)
        } else if MP4MetadataWriter.canWriteMetadata(to: url) {
            try MP4MetadataWriter.write(draft, to: url)
        } else if AIFFMetadataWriter.canWriteMetadata(to: url) {
            try AIFFMetadataWriter.write(draft, to: url)
        } else {
            try AdditionalAudioMetadata.write(draft, to: url)
        }
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
                // patch applies to the item's values. The draft's other text values are the ones the item
                // already shows, which it records again as its edited values.
                let baseDraft = try await itemDraftResolvingPlaceholders(for: item, patching: patch.fields)
                let patchedDraft = patch.applying(to: baseDraft)
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

import AVFoundation
import Foundation
import SwiftData

extension LibraryService {
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

    /// An ordinary read failure leaves the artwork to the file's tags; cancellation or invalidation stops the draft.
    private func libraryArtworkForDraft(of item: MediaItem, includesArtwork: Bool) async throws -> Data? {
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

    private func draftByApplyingExtendedInfo(
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

    private func draftByApplyingMP4Metadata(
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

    func allMetadata(for asset: AVURLAsset) async -> [AVMetadataItem] {
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

    func mp4Metadata(for url: URL) async -> MP4MetadataReadResult? {
        guard MP4MetadataWriter.canWriteMetadata(to: url) else { return nil }
        return try? await Task.detached(priority: .utility) {
            try MP4MetadataReader.read(from: url)
        }.value
    }

}

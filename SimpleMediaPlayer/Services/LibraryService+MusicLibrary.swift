import Foundation
import SwiftData

/// Music library songs reach the player and the library only through exported copies. Playback keeps
/// the copy in a temporary session; import stages the copy, writes the song's Music metadata into it,
/// then hands it to the regular import so validation, duplicate checks, and registration stay shared.
extension LibraryService {
    enum MusicLibraryPlaybackOutcome {
        case ready(TransientPlaybackSession)
        case failed(String)
        case cancelled
    }

    func beginMusicLibraryPreparation(
        _ purpose: MusicLibraryPreparation.Purpose, totalCount: Int
    ) -> MusicLibraryPreparation {
        musicLibraryPreparation?.terminate(.replaced)
        let preparation = MusicLibraryPreparation(purpose: purpose, totalCount: totalCount)
        musicLibraryPreparation = preparation
        return preparation
    }

    func cancelMusicLibraryPreparation() {
        musicLibraryPreparation?.terminate(.cancelled)
        musicLibraryPreparation = nil
    }

    /// Clears the panel for a finished preparation and says whether its result may still be applied.
    private func finishMusicLibraryPreparation(_ preparation: MusicLibraryPreparation) -> Bool {
        if musicLibraryPreparation === preparation { musicLibraryPreparation = nil }
        return preparation.termination == nil
    }

    /// Exports one song into a new session. Returns `.cancelled` when the preparation was cancelled or
    /// replaced, including when its export had already finished; that session's files are removed.
    func prepareMusicLibraryPlayback(of track: MusicLibraryTrack) async -> MusicLibraryPlaybackOutcome {
        let preparation = beginMusicLibraryPreparation(.playback, totalCount: 1)
        preparation.advance(to: 0, title: track.displayTitle)
        let task = Task { try await self.makeTransientSession(for: track) }
        preparation.attach(task)
        let result = await task.result
        let isCurrent = finishMusicLibraryPreparation(preparation)
        switch result {
        case let .success(session):
            guard isCurrent else {
                session.end()
                return .cancelled
            }
            return .ready(session)
        case let .failure(error):
            guard isCurrent, error is CancellationError == false else { return .cancelled }
            return .failed(L10n.format("Could not play “%@”: %@", track.displayTitle, error.localizedDescription))
        }
    }

    /// Returns nil when the preparation was replaced by a newer one. Cancelling imports nothing: staged
    /// files are removed and no item is registered.
    func importMusicLibraryTracks(
        _ tracks: [MusicLibraryTrack], into context: ModelContext, existingItems: [MediaItem]
    ) async -> MusicLibraryImportResult? {
        guard tracks.isEmpty == false else { return nil }
        let preparation = beginMusicLibraryPreparation(.importing, totalCount: tracks.count)
        let directory: URL
        do {
            directory = try MusicLibraryTemporaryFiles.makeDirectory(for: .importStaging, in: temporaryDirectoryURL)
        } catch {
            _ = finishMusicLibraryPreparation(preparation)
            return MusicLibraryImportResult(messages: [error.localizedDescription])
        }
        // The pre-check runs in the attached task so cancelling the panel also stops its file probes.
        let task = Task {
            let alreadyImported = try await self.musicLibraryItemIDsWithAvailableFiles(
                in: context, existingItems: existingItems
            )
            return try await self.stageMusicLibraryTracks(
                tracks, skipping: alreadyImported, in: directory, context: context, preparation: preparation
            )
        }
        preparation.attach(task)
        let result = await task.result
        let isCurrent = finishMusicLibraryPreparation(preparation)
        guard isCurrent, case let .success(staging) = result else {
            MusicLibraryTemporaryFiles.removeDirectoryInBackground(directory)
            // The pre-check and staging only throw for cancellation; per-song failures become messages.
            return preparation.termination == .replaced ? nil : MusicLibraryImportResult(wasCancelled: true)
        }
        defer { MusicLibraryTemporaryFiles.removeDirectoryInBackground(directory) }
        guard staging.urls.isEmpty == false else {
            return MusicLibraryImportResult(skippedCount: staging.skippedCount, messages: staging.messages)
        }
        let summary = await importFiles(
            from: staging.urls, overrides: staging.overrides, into: context, existingItems: existingItems
        )
        return MusicLibraryImportResult(
            importedCount: summary.createdCount,
            skippedCount: staging.skippedCount + summary.duplicateCount,
            messages: staging.messages + summary.errors
        )
    }
}

private extension LibraryService {
    struct MusicLibraryStaging {
        var urls: [URL] = []
        var overrides: [URL: MediaImportOverride] = [:]
        var messages: [String] = []
        var skippedCount = 0
    }

    func makeTransientSession(for track: MusicLibraryTrack) async throws -> TransientPlaybackSession {
        let assetURL = try track.validatedAssetURL()
        let directory = try MusicLibraryTemporaryFiles.makeDirectory(for: .playback, in: temporaryDirectoryURL)
        do {
            let output = try await MusicLibraryTrackExporter.export(
                assetURL: assetURL, to: directory, baseName: track.exportBaseName
            )
            try Task.checkCancellation()
            let item = try makeTransientItem(for: track, output: output)
            return TransientPlaybackSession(directory: directory, items: [item])
        } catch {
            MusicLibraryTemporaryFiles.removeDirectoryInBackground(directory)
            throw error
        }
    }

    func makeTransientItem(for track: MusicLibraryTrack, output: MusicLibraryTrackExporter.Output) throws -> MediaItem {
        #if os(macOS)
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = try output.url.bookmarkData(
            options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let values = track.metadataValues
        return MediaItem(
            title: values.title ?? track.displayTitle,
            artist: values.artist ?? "Unknown Artist",
            album: values.album ?? "Unknown Album",
            genre: values.genre,
            year: values.year,
            trackNumber: values.trackNumber,
            comment: values.comment,
            albumArtist: values.albumArtist,
            composer: values.composer,
            discNumber: values.discNumber,
            isCompilation: track.isCompilation,
            duration: track.duration > 0 ? track.duration : output.duration,
            isVideo: false,
            lyricsRaw: track.normalizedLyrics,
            bookmarkData: bookmark,
            fileName: output.url.lastPathComponent,
            musicLibraryItemID: track.libraryItemID
        )
    }

    /// Songs already imported from Music are skipped by their persistent ID, because every export
    /// produces different bytes and the fingerprint check cannot recognize them.
    func musicLibraryItemIDsWithAvailableFiles(
        in context: ModelContext, existingItems: [MediaItem]
    ) async throws -> Set<String> {
        var itemsByMusicID: [String: [MediaItem]] = [:]
        let fetched = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        for item in existingItems + fetched {
            guard let musicID = item.musicLibraryItemID, isLibraryItemLive(item, in: context) else { continue }
            if itemsByMusicID[musicID]?.contains(where: { $0.id == item.id }) != true {
                itemsByMusicID[musicID, default: []].append(item)
            }
        }
        var available: Set<String> = []
        for (musicID, items) in itemsByMusicID {
            try Task.checkCancellation()
            if await hasAvailableFile(for: items, in: context) { available.insert(musicID) }
        }
        return available
    }

    /// The pre-check runs before staging starts; another scene may delete the item meanwhile, so a skip is
    /// confirmed against the current library. The serialized import still makes the final decision.
    func isMusicLibraryTrackStillImported(_ musicID: String, in context: ModelContext) async -> Bool {
        let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.musicLibraryItemID == musicID })
        let items = (try? context.fetch(descriptor)) ?? []
        return await hasAvailableFile(for: items, in: context)
    }

    func stageMusicLibraryTracks(
        _ tracks: [MusicLibraryTrack], skipping alreadyImported: Set<String>,
        in directory: URL, context: ModelContext, preparation: MusicLibraryPreparation
    ) async throws -> MusicLibraryStaging {
        var staging = MusicLibraryStaging()
        for (index, selected) in tracks.enumerated() {
            try Task.checkCancellation()
            preparation.advance(to: index, title: selected.displayTitle)
            if alreadyImported.contains(selected.libraryItemID),
               await isMusicLibraryTrackStillImported(selected.libraryItemID, in: context) {
                try Task.checkCancellation()
                staging.skippedCount += 1
                staging.messages.append(L10n.format("“%@” is already in your library.", selected.displayTitle))
                continue
            }
            var track = selected
            do {
                let assetURL = try track.validatedAssetURL()
                track.artworkData = await selected.resolvedArtworkData()
                try Task.checkCancellation()
                let output = try await MusicLibraryTrackExporter.export(
                    assetURL: assetURL, to: directory, baseName: track.exportBaseName
                )
                try Task.checkCancellation()
                let isEmbedded = await Self.embedMusicLibraryMetadata(of: track, into: output.url)
                try Task.checkCancellation()
                staging.urls.append(output.url)
                // Music's text fields are authoritative even when embedding failed; artwork and lyrics
                // that Music lacks keep the file's own, matching what the embedding writes.
                staging.overrides[output.url] = MediaImportOverride(
                    values: track.metadataValues, artworkData: track.artworkData, lyrics: track.normalizedLyrics,
                    musicLibraryItemID: track.libraryItemID, replacesTextFields: true, isEmbeddedInFile: isEmbedded
                )
                if output.isTranscoded {
                    staging.messages.append(L10n.format("“%@” was converted to AAC.", track.displayTitle))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                staging.messages.append("\(track.displayTitle): \(error.localizedDescription)")
            }
        }
        preparation.advance(to: tracks.count, title: nil)
        return staging
    }
}

extension LibraryService {
    /// Best effort: the import override still applies the same values when a format has no writer or
    /// the write fails. The rewriters replace the file atomically, so a failure leaves it unchanged.
    /// Cancelling the caller cancels the rewrite, whose cancellation checks run in the detached task.
    nonisolated static func embedMusicLibraryMetadata(of track: MusicLibraryTrack, into url: URL) async -> Bool {
        let rewrite = Task.detached(priority: .utility) {
            let values = track.metadataValues
            let draft = MediaMetadataEditDraft(
                title: values.title ?? "", artist: values.artist ?? "", album: values.album ?? "",
                genre: values.genre ?? "", year: values.year ?? "", trackNumber: values.trackNumber ?? "",
                comment: values.comment ?? "", albumArtist: values.albumArtist ?? "",
                composer: values.composer ?? "", discNumber: values.discNumber ?? "",
                isCompilation: track.isCompilation, artworkData: track.artworkData,
                lyrics: track.normalizedLyrics ?? "", editsTextMetadata: true,
                editsArtwork: track.artworkData != nil, editsLyrics: track.normalizedLyrics != nil
            )
            do {
                if ID3TagWriter.canWriteMetadata(to: url) {
                    try ID3TagWriter.write(draft, to: url)
                } else if MP4MetadataWriter.canWriteMetadata(to: url) {
                    try MP4MetadataWriter.write(draft, to: url)
                } else if AIFFMetadataWriter.canWriteMetadata(to: url) {
                    try AIFFMetadataWriter.write(draft, to: url)
                } else if AdditionalAudioMetadata.canWrite(to: url) {
                    try AdditionalAudioMetadata.write(draft, to: url)
                } else {
                    return false
                }
                return true
            } catch {
                return false
            }
        }
        return await withTaskCancellationHandler {
            await rewrite.value
        } onCancel: {
            rewrite.cancel()
        }
    }
}

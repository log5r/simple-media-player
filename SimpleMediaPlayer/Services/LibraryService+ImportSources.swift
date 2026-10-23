import AVFoundation
import Foundation
import SwiftData

extension LibraryService {
    private static let lyricsKeyNeedles = ["lyrics", "ult", "uslt", "sylt", "©lyr", "lyr"]

    private static func firstNonblank(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    /// Returns the item with the merged values it was made from, before the fallbacks for missing values.
    func makeMediaItem(
        from sourceURL: URL, importFingerprint: String, musicSession: MusicLibraryMetadataSession
    ) async throws -> (MediaItem, MediaMetadataEmbeddedValues) {
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
        return (item, values)
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
                                       music?.artist, mp4?.values.artist, raw.artist),
            album: Self.firstNonblank(additional?.values.album, id3?.album, extended?.album,
                                      music?.album, mp4?.values.album, raw.album),
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
            discNumber: await metadata.firstDisplayString(
                whereKeyContains: ["disc number", "discnumber", "disk", "tpos", "tpa"]
            ),
            isCompilation: await metadata.firstBool(whereKeyContains: Self.compilationKeyNeedles)
        )
    }

    private func isVideoFile(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        }
        return type.conforms(to: .movie)
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

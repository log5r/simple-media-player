import Foundation
import SwiftData

extension LibraryService {
    func registerTransformedCopy(
        of source: MediaItem,
        renderedFileURL: URL,
        title: String,
        duration: TimeInterval,
        artworkSnapshot: LibraryArtworkSnapshot? = nil,
        in context: ModelContext
    ) async throws -> MediaItem {
        let sourceContext = source.modelContext
        try validateCopySource(source, in: sourceContext)
        var sourceSnapshot = TransformedTrackSourceSnapshot(item: source)
        let artworkData = try await artworkForCopy(of: source, snapshot: artworkSnapshot)
        try validateCopySource(source, in: sourceContext)
        sourceSnapshot.artworkData = artworkData
        return try await registerTransformedCopy(
            of: sourceSnapshot, renderedFileURL: renderedFileURL, title: title, duration: duration,
            in: context
        )
    }

    func registerTransformedCopy(
        of source: TransformedTrackSourceSnapshot,
        renderedFileURL: URL,
        title: String,
        duration: TimeInterval,
        in context: ModelContext
    ) async throws -> MediaItem {
        try Task.checkCancellation()
        try validateTransformedSource(source, in: context)
        let id = UUID()
        let copiedURL = try await copyTransformedFileIntoMediaDirectory(renderedFileURL, id: id)
        do {
            let bookmark = try await makeManagedFileBookmark(for: copiedURL)
            // The export may be cancelled, or its source deleted, while the copy and the bookmark run.
            try Task.checkCancellation()
            try validateTransformedSource(source, in: context)
            let item = MediaItem(
                id: id,
                title: title,
                artist: source.metadata.artist,
                album: source.metadata.album,
                genre: source.metadata.genre,
                year: source.metadata.year,
                trackNumber: source.metadata.trackNumber,
                comment: source.metadata.comment,
                albumArtist: source.metadata.albumArtist,
                composer: source.metadata.composer,
                discNumber: source.metadata.discNumber,
                isCompilation: source.metadata.isCompilation,
                duration: duration.isFinite ? duration : 0,
                isVideo: false,
                lyricsRaw: source.lyricsRaw,
                bookmarkData: bookmark,
                artworkData: source.artworkData,
                fileName: copiedURL.lastPathComponent
            )
            try source.applyEditedMetadata(to: item, title: title)
            context.insert(item)
            do {
                try context.save()
            } catch {
                deleteLibraryModel(item, from: context)
                throw error
            }
            return item
        } catch {
            // Awaited on the queue, so the unregistered copy is gone once the caller sees the error.
            await FileSystemWorkQueue.run(qos: .userInitiated) { try? FileManager.default.removeItem(at: copiedURL) }
            throw error
        }
    }

    private func validateTransformedSource(_ source: TransformedTrackSourceSnapshot, in context: ModelContext) throws {
        guard let sourceID = source.registeredID else { return }
        let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == sourceID })
        guard try context.fetchCount(descriptor) > 0 else { throw CancellationError() }
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
}

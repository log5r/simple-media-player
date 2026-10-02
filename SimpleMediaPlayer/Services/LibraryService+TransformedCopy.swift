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
        let sourceSnapshot = TransformedTrackSourceSnapshot(item: source)
        let artworkData = try await artworkForCopy(of: source, snapshot: artworkSnapshot)
        try validateCopySource(source, in: sourceContext)
        return try await registerTransformedCopy(
            of: sourceSnapshot, renderedFileURL: renderedFileURL, title: title, duration: duration,
            artworkSnapshot: LibraryArtworkSnapshot(data: artworkData), in: context
        )
    }

    func registerTransformedCopy(
        of source: TransformedTrackSourceSnapshot,
        renderedFileURL: URL,
        title: String,
        duration: TimeInterval,
        artworkSnapshot: LibraryArtworkSnapshot,
        in context: ModelContext
    ) async throws -> MediaItem {
        try Task.checkCancellation()
        try validateTransformedSource(source, in: context)
        let id = UUID()
        let copiedURL = try await copyTransformedFileIntoMediaDirectory(renderedFileURL, id: id)
        var didRegister = false
        defer {
            if didRegister == false { try? FileManager.default.removeItem(at: copiedURL) }
        }
        try Task.checkCancellation()
        try validateTransformedSource(source, in: context)
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
            artworkData: artworkSnapshot.data,
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

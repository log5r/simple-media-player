import Foundation

/// The persisted location of a library file, captured on the main actor so workers can resolve it.
nonisolated struct MediaFileReference: Sendable {
    let id: UUID
    let bookmarkData: Data
    let fileName: String
}

/// Only value snapshots cross the actor boundary; bookmark resolution and file probes run in the worker.
nonisolated struct EmbeddedMetadataEditabilityChecker: Sendable {
    typealias Input = MediaFileReference

    private let resolve: @Sendable (Data, URL) -> URL
    private let canWrite: @Sendable (URL) -> Bool

    init(
        resolve: @escaping @Sendable (Data, URL) -> URL = Self.resolve,
        canWrite: @escaping @Sendable (URL) -> Bool = Self.canWrite
    ) {
        self.resolve = resolve
        self.canWrite = canWrite
    }

    func editableIDs(
        for inputs: [Input],
        fallbackDirectory: @escaping @Sendable () -> URL
    ) async throws -> Set<UUID> {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let directory = fallbackDirectory()
            var editableIDs: Set<UUID> = []
            for input in inputs {
                try Task.checkCancellation()
                let isEditable = try autoreleasepool {
                    let url = resolve(input.bookmarkData, directory.appendingPathComponent(input.fileName))
                    try Task.checkCancellation()
                    return try inspect(url)
                }
                if isEditable { editableIDs.insert(input.id) }
            }
            try Task.checkCancellation()
            return editableIDs
        }
        return try await withTaskCancellationHandler {
            let ids = try await task.value
            try Task.checkCancellation()
            return ids
        } onCancel: {
            task.cancel()
        }
    }

    func canWriteMetadata(to url: URL) async throws -> Bool {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { try inspect(url) }
        return try await withTaskCancellationHandler {
            let isEditable = try await task.value
            try Task.checkCancellation()
            return isEditable
        } onCancel: {
            task.cancel()
        }
    }

    private func inspect(_ url: URL) throws -> Bool {
        try Task.checkCancellation()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let isEditable = canWrite(url)
        try Task.checkCancellation()
        return isEditable
    }

    static func resolve(_ bookmarkData: Data, _ fallbackURL: URL) -> URL {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )) ?? fallbackURL
    }

    static func canWrite(_ url: URL) -> Bool {
        ID3TagWriter.canWriteMetadata(to: url)
            || MP4MetadataWriter.canWriteMetadata(to: url)
            || AIFFMetadataWriter.canWriteMetadata(to: url)
            || AdditionalAudioMetadata.canWrite(to: url)
    }
}

import Foundation

/// Temporary directories for Music library exports. Playback sessions and import staging each use their
/// own directory, so removing one cannot touch files another session still reads.
nonisolated enum MusicLibraryTemporaryFiles {
    enum Kind: String, Sendable {
        case playback = "Playback"
        case importStaging = "ImportStaging"
    }

    static func rootDirectory(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        temporaryDirectory.appendingPathComponent("MusicLibrary", isDirectory: true)
    }

    static func makeDirectory(
        for kind: Kind, in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let directory = rootDirectory(in: temporaryDirectory)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func removeDirectoryInBackground(_ directory: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// No session survives a launch, so everything left by an earlier process can go. The root is
    /// renamed first, so directories that sessions create under the new root while the slow removal
    /// runs are never touched by it. Analysis cache entries of crashed playback sessions are removed
    /// too: their keys name files under the old root, so nothing could reuse or find them later.
    @discardableResult
    static func removeLeftoversInBackground(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        analysisCacheDirectory: URL? = MusicAnalysisCache.defaultDirectory
    ) -> Task<Void, Never> {
        let root = rootDirectory(in: temporaryDirectory)
        let trashed = temporaryDirectory
            .appendingPathComponent("\(trashPrefix)\(UUID().uuidString)", isDirectory: true)
        // Only the rename stays synchronous; the directory scan and removals may be slow.
        try? FileManager.default.moveItem(at: root, to: trashed)
        return Task.detached(priority: .utility) {
            // Includes trash from earlier launches that were interrupted before removing their own.
            let siblings = (try? FileManager.default.contentsOfDirectory(
                at: temporaryDirectory, includingPropertiesForKeys: nil
            )) ?? []
            for directory in siblings where directory.lastPathComponent.hasPrefix(trashPrefix) {
                removeAnalysisEntries(ofPlaybackIn: directory, formerRoot: root, cacheDirectory: analysisCacheDirectory)
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Playback files sat at the same relative path under `formerRoot` when they were analyzed.
    private static func removeAnalysisEntries(ofPlaybackIn trash: URL, formerRoot: URL, cacheDirectory: URL?) {
        guard let cacheDirectory else { return }
        let manager = FileManager.default
        let playback = Kind.playback.rawValue
        let sessions = (try? manager.contentsOfDirectory(
            at: trash.appendingPathComponent(playback, isDirectory: true), includingPropertiesForKeys: nil
        )) ?? []
        for session in sessions {
            let files = (try? manager.contentsOfDirectory(
                at: session, includingPropertiesForKeys: [.isRegularFileKey]
            )) ?? []
            for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let original = formerRoot
                    .appendingPathComponent(playback, isDirectory: true)
                    .appendingPathComponent(session.lastPathComponent, isDirectory: true)
                    .appendingPathComponent(file.lastPathComponent)
                if let entry = MusicAnalysisCache.entryURL(
                    forOriginalURL: original, attributesOf: file, in: cacheDirectory
                ) {
                    try? manager.removeItem(at: entry)
                }
            }
        }
    }

    private static let trashPrefix = "MusicLibrary-Trash-"
}

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
    /// runs are never touched by it.
    @discardableResult
    static func removeLeftoversInBackground(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Task<Void, Never> {
        let root = rootDirectory(in: temporaryDirectory)
        var trash: [URL] = []
        let trashed = temporaryDirectory
            .appendingPathComponent("\(trashPrefix)\(UUID().uuidString)", isDirectory: true)
        if (try? FileManager.default.moveItem(at: root, to: trashed)) != nil {
            trash.append(trashed)
        }
        // Earlier launches may have been interrupted before their own trash was removed.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: nil
        )) ?? []
        trash += siblings.filter { $0.lastPathComponent.hasPrefix(trashPrefix) && $0 != trashed }
        let directories = trash
        return Task.detached(priority: .utility) {
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private static let trashPrefix = "MusicLibrary-Trash-"
}

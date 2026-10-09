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

    /// No session survives a launch, so everything left by an earlier process can go.
    @discardableResult
    static func removeLeftoversInBackground(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Task<Void, Never> {
        let root = rootDirectory(in: temporaryDirectory)
        return Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

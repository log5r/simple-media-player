import CryptoKit
import Foundation

nonisolated enum MusicAnalysisCache {
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimpleMediaPlayer/MusicAnalysis", isDirectory: true)
    }

    static func entryURL(for url: URL, in directory: URL? = defaultDirectory) -> URL? {
        entryURL(forOriginalURL: url, attributesOf: url, in: directory)
    }

    /// The key `entryURL(for: original)` gave while the file was at `original`, for a file since moved
    /// to `fileURL` with its size and modification date unchanged.
    static func entryURL(
        forOriginalURL original: URL, attributesOf fileURL: URL, in directory: URL? = defaultDirectory
    ) -> URL? {
        guard let directory else { return nil }
        var fileURL = fileURL
        // The same URL instance can outlive a rewrite; read the current size and date.
        fileURL.removeAllCachedResourceValues()
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        let identity = "v5|\(original.standardizedFileURL.absoluteString)|\(size)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    static func read(at entry: URL) -> MusicAnalysis? {
        guard let data = try? Data(contentsOf: entry) else { return nil }
        return try? JSONDecoder().decode(MusicAnalysis.self, from: data)
    }

    static func write(_ analysis: MusicAnalysis, at entry: URL) {
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? FileManager.default.createDirectory(
            at: entry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: entry, options: .atomic)
    }

    /// Moves `entry` to the key of the file now at `url`.
    /// Call only after a rewrite that leaves the audio unchanged.
    static func carryOver(_ entry: URL?, to url: URL, in directory: URL? = defaultDirectory) {
        guard let entry, let destination = entryURL(for: url, in: directory), destination != entry else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: entry.path) else { return }
        try? manager.removeItem(at: destination)
        try? manager.moveItem(at: entry, to: destination)
    }
}

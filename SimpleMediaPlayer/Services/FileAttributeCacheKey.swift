import CryptoKit
import Foundation

/// Names the entries of caches that hold one file per media file, keyed by the media file's URL, size, and
/// modification date, so a lookup reads only its own entry and a changed file misses it.
nonisolated enum FileAttributeCacheKey {
    /// The size and modification date of the file at `url`, read again even if this URL instance cached them.
    static func attributes(of url: URL) -> (size: Int, modificationDate: TimeInterval)? {
        var url = url
        // The same URL instance can outlive a rewrite; read the current size and date.
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        return (size, modified.timeIntervalSince1970)
    }

    /// The file name, without extension, of the entry for `original` with the given attributes.
    static func name(version: String, original: URL, size: Int, modificationDate: TimeInterval) -> String {
        let identity = "\(version)|\(original.standardizedFileURL.absoluteString)|\(size)|\(modificationDate)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Moves `entry` to `destination`, replacing an entry already there.
    /// Call only after a rewrite that leaves the audio unchanged.
    static func move(_ entry: URL?, to destination: URL?) {
        guard let entry, let destination, destination != entry else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: entry.path) else { return }
        try? manager.removeItem(at: destination)
        try? manager.moveItem(at: entry, to: destination)
    }
}

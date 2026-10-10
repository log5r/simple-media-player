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

    /// Test hook: runs in `store` between the key check and the write, so tests can change the file there.
    @TaskLocal static var willStore: @Sendable () -> Void = {}

    /// Calls `write` to fill `entry`, the key `currentEntry` gave when the value's computation started, only if
    /// it still gives that key afterward. A tag save or a removal of the file can finish during the computation;
    /// a value written at the old key could not be found again and would stay in the cache.
    /// The save's carry-over or the removal's cleanup may run before or after the write. If it runs after, it
    /// moves or removes the entry itself. If it ran before, it found no entry, and the check after the write
    /// sees the changed or missing file and removes the entry. Removing an entry at a key the file no longer has
    /// loses nothing that a lookup could find, unless a failed in-place save restores that key: then the value is
    /// computed again.
    static func store(at entry: URL, currentEntry: () -> URL?, write: () -> Void) {
        guard currentEntry() == entry else { return }
        willStore()
        write()
        if currentEntry() != entry {
            try? FileManager.default.removeItem(at: entry)
        }
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

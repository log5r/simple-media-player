import Foundation

/// Measured loudness gains, one small file per media file, so a lookup reads only its own entry and a large
/// library keeps every gain until the system purges the Caches directory.
nonisolated enum AudioLoudnessCache {
    /// Earlier versions kept at most 256 gains in one dictionary under this key, keyed by `path|size|mtime`.
    static let legacyDefaultsKey = "audioLoudnessNormalizationCache.v1"
    private static let version = "loudness.v1"
    private static let pathExtension = "gain"

    static let defaultDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("SimpleMediaPlayer/Loudness", isDirectory: true)

    static func entryURL(for url: URL, in directory: URL? = defaultDirectory) -> URL? {
        entryURL(forOriginalURL: url, attributesOf: url, in: directory)
    }

    /// The key `entryURL(for: original)` gave while the file was at `original`, for a file since moved
    /// to `fileURL` with its size and modification date unchanged.
    static func entryURL(
        forOriginalURL original: URL, attributesOf fileURL: URL, in directory: URL? = defaultDirectory
    ) -> URL? {
        guard let directory, let attributes = FileAttributeCacheKey.attributes(of: fileURL) else { return nil }
        if directory == defaultDirectory { _ = legacyMigration }
        return entryURL(
            original: original, size: attributes.size, modificationDate: attributes.modificationDate, in: directory
        )
    }

    static func read(at entry: URL) -> Float? {
        guard let data = try? Data(contentsOf: entry), data.count == MemoryLayout<UInt32>.size else { return nil }
        let bits = data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Float(bitPattern: bits)
    }

    /// Writes atomically, so concurrent writers of the same entry leave one complete value.
    static func write(_ gain: Float, at entry: URL) {
        let bits = gain.bitPattern
        let data = Data((0..<4).map { UInt8(truncatingIfNeeded: bits >> ((3 - $0) * 8)) })
        try? FileManager.default.createDirectory(
            at: entry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: entry, options: .atomic)
    }

    /// Writes `gain` at `entry`, the key of the file at `url` when its measurement started, only if the file
    /// still has that key afterward, as `FileAttributeCacheKey.store` describes.
    static func store(_ gain: Float, at entry: URL, for url: URL, in directory: URL?) {
        FileAttributeCacheKey.store(
            at: entry, currentEntry: { entryURL(for: url, in: directory) }, write: { write(gain, at: entry) }
        )
    }

    /// Moves `entry` to the key of the file now at `url`.
    /// Call only after a rewrite that leaves the audio unchanged.
    static func carryOver(_ entry: URL?, to url: URL, in directory: URL? = defaultDirectory) {
        guard let entry else { return }
        FileAttributeCacheKey.move(entry, to: entryURL(for: url, in: directory))
    }

    /// Moves the gains of earlier versions out of `defaults` into `directory` and removes the dictionary, which
    /// nothing reads afterward. An entry already in `directory` is kept. A key or value that does not have the
    /// earlier format is dropped; that file's gain is measured again when needed.
    static func migrateLegacyEntries(from defaults: UserDefaults, into directory: URL) {
        guard let legacy = defaults.dictionary(forKey: legacyDefaultsKey) else { return }
        for (key, value) in legacy {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let entry = legacyEntryURL(forKey: key, in: directory),
                  FileManager.default.fileExists(atPath: entry.path) == false
            else { continue }
            write(Float(truncating: number), at: entry)
        }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    /// Runs once per process, before the first access to the default directory, which happens off the main actor:
    /// in playback's measurement task, a metadata save, or temporary file cleanup.
    private static let legacyMigration: Void = {
        guard let directory = defaultDirectory else { return }
        migrateLegacyEntries(from: .standard, into: directory)
    }()

    /// Earlier keys were `"\(url.path)|\(fileSize)|\(modificationDate.timeIntervalSince1970)"`. The path can
    /// contain `|`, so the size and date are taken from the end. Both must read back as the same text, so the
    /// entry gets the name that a lookup of the same file computes.
    private static func legacyEntryURL(forKey key: String, in directory: URL) -> URL? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let path = parts.dropLast(2).joined(separator: "|")
        let sizeText = parts[parts.count - 2]
        let dateText = parts[parts.count - 1]
        guard path.hasPrefix("/"),
              let size = Int(sizeText), size >= 0, String(size) == sizeText,
              let modificationDate = TimeInterval(dateText), "\(modificationDate)" == dateText
        else { return nil }
        return entryURL(
            original: URL(fileURLWithPath: path, isDirectory: false),
            size: size,
            modificationDate: modificationDate,
            in: directory
        )
    }

    private static func entryURL(original: URL, size: Int, modificationDate: TimeInterval, in directory: URL) -> URL {
        let name = FileAttributeCacheKey.name(
            version: version, original: original, size: size, modificationDate: modificationDate
        )
        return directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
    }
}

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
        guard let directory, let attributes = FileAttributeCacheKey.attributes(of: fileURL) else { return nil }
        let name = FileAttributeCacheKey.name(
            version: "v5", original: original, size: attributes.size, modificationDate: attributes.modificationDate
        )
        return directory.appendingPathComponent(name).appendingPathExtension("json")
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
        guard let entry else { return }
        FileAttributeCacheKey.move(entry, to: entryURL(for: url, in: directory))
    }
}

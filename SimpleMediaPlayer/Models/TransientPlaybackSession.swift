import Foundation

/// The temporary files behind playback that is not saved to the library. The player retains the session
/// while one of its items is current or queued; ending it removes the directory in the background.
/// Stopping keeps the current item, so only switching to other media, clearing, or a replaced
/// preparation ends a session.
@MainActor
final class TransientPlaybackSession: Identifiable {
    let id = UUID()
    let directory: URL
    /// Never inserted into a `ModelContext`; their bookmarks point into `directory`.
    let items: [MediaItem]
    private(set) var isEnded = false
    private var cleanupTask: Task<Void, Never>?
    private let analysisCacheDirectory: URL?
    /// Captured at creation so the nonisolated deinit can clean up without touching the items.
    private let fileURLs: [URL]

    init(directory: URL, items: [MediaItem], analysisCacheDirectory: URL? = MusicAnalysisCache.defaultDirectory) {
        self.directory = directory
        self.items = items
        self.analysisCacheDirectory = analysisCacheDirectory
        fileURLs = items.map { directory.appendingPathComponent($0.fileName) }
    }

    deinit {
        guard cleanupTask == nil else { return }
        Self.removeFiles(in: directory, items: fileURLs, analysisCacheDirectory: analysisCacheDirectory)
    }

    func contains(_ itemID: UUID) -> Bool {
        items.contains { $0.id == itemID }
    }

    func end() {
        guard isEnded == false else { return }
        isEnded = true
        cleanupTask = Self.removeFiles(in: directory, items: fileURLs, analysisCacheDirectory: analysisCacheDirectory)
    }

    /// Analysis cache entries are keyed by each file's path and attributes, which only this session's
    /// files ever match, so they are removed together with the files; the key is read first.
    @discardableResult
    nonisolated private static func removeFiles(
        in directory: URL, items: [URL], analysisCacheDirectory: URL?
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let entries = items.compactMap { MusicAnalysisCache.entryURL(for: $0, in: analysisCacheDirectory) }
            try? FileManager.default.removeItem(at: directory)
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    func awaitCleanup() async {
        await cleanupTask?.value
    }
}

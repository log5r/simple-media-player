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

    init(directory: URL, items: [MediaItem]) {
        self.directory = directory
        self.items = items
    }

    deinit {
        guard cleanupTask == nil else { return }
        MusicLibraryTemporaryFiles.removeDirectoryInBackground(directory)
    }

    func contains(_ itemID: UUID) -> Bool {
        items.contains { $0.id == itemID }
    }

    func end() {
        guard isEnded == false else { return }
        isEnded = true
        let directory = directory
        cleanupTask = Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func awaitCleanup() async {
        await cleanupTask?.value
    }
}

import Foundation

extension LibraryService {
    /// Bookmarks a file the app has just written, such as a transformed copy or a Music library export, on
    /// `FileSystemWorkQueue` instead of the caller's actor.
    ///
    /// A cancelled caller stops waiting at once, including while it waits for a `managedFileBookmarkLimiter` slot.
    /// A bookmark already running then finishes on the queue and is discarded, which leaves nothing behind because
    /// creating a bookmark writes no file. It keeps its slot until then, so on a stalled volume at most two such
    /// bookmarks block the queue however often the caller cancels and retries.
    func makeManagedFileBookmark(for url: URL) async throws -> Data {
        let makeBookmark = importFileOperations.makeBookmark
        let bookmark = try await FileSystemWorkQueue.runCancellable(
            qos: .userInitiated, limiter: managedFileBookmarkLimiter
        ) {
            Result { try makeBookmark(url) }
        }.get()
        // The bookmark may finish just as the caller is cancelled; a cancelled request reports no result.
        try Task.checkCancellation()
        return bookmark
    }
}

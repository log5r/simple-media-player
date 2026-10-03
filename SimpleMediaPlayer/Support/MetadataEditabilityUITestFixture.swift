import Foundation

#if DEBUG
nonisolated enum MetadataEditabilityUITestFixture {
    @MainActor
    static func makeLibraryService() -> LibraryService {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing-delayed-editability") else {
            return LibraryService()
        }
        return LibraryService(editabilityChecker: EmbeddedMetadataEditabilityChecker(canWrite: canWrite))
    }

    private static func canWrite(to url: URL) -> Bool {
        // Only the first selected track is slow. Reopening a different selection must stay responsive
        // even when the old synchronous read has not finished or was cancelled before it started.
        guard url.lastPathComponent == "ui-test-1.mp3" else { return true }
        Thread.sleep(forTimeInterval: 10)
        return false
    }
}
#endif

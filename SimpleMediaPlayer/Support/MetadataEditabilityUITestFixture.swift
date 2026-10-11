import Foundation
import SwiftUI

#if DEBUG
nonisolated enum MetadataEditabilityUITestFixture {
    private static let saveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SimpleMediaPlayer-MetadataSaveUITest", isDirectory: true)

    @MainActor
    static func makeLibraryService() -> LibraryService {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-cleanup-metadata-save") {
            try? FileManager.default.removeItem(at: saveDirectory)
        }
        if arguments.contains("--ui-testing-delayed-metadata-save") {
            return LibraryService(mediaDirectoryURL: saveDirectory, beforeMetadataWrite: delaySave)
        }
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing-delayed-editability") else {
            return LibraryService()
        }
        return LibraryService(editabilityChecker: EmbeddedMetadataEditabilityChecker(canWrite: canWrite))
    }

    /// A small tagged file exercises the real ID3 writer without touching the user's media directory.
    @MainActor
    static func prepareSaveFile(for item: MediaItem, index: Int) throws {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing-delayed-metadata-save") else { return }
        if index == 1 {
            try? FileManager.default.removeItem(at: saveDirectory)
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        }
        let url = saveDirectory.appendingPathComponent(item.fileName)
        // Empty ID3v2.4 metadata followed by an MPEG audio frame header and padded payload.
        var data = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 0xFF, 0xFB, 0x90, 0x64])
        data.append(Data(repeating: 0, count: 413))
        try data.write(to: url)
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        item.bookmarkData = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        try ID3TagWriter.write(MediaMetadataEditDraft(item: item), to: url)
    }

    private static func delaySave(to url: URL) async throws {
        guard url.lastPathComponent == "ui-test-2.mp3" else { return }
        // Suspending here leaves the main actor and cooperative pool available for Stop.
        try await Task.sleep(for: .seconds(30))
    }

    static func savedFileTitles() async -> String {
        await FileSystemWorkQueue.run {
            (1...3).map { index in
                let url = saveDirectory.appendingPathComponent("ui-test-\(index).mp3")
                return (try? ID3TagWriter.readMetadata(from: url)?.title) ?? ""
            }.joined(separator: "|")
        }
    }

    private static func canWrite(to url: URL) -> Bool {
        // Only the first selected track is slow. Reopening a different selection must stay responsive
        // even when the old synchronous read has not finished or was cancelled before it started.
        guard url.lastPathComponent == "ui-test-1.mp3" else { return true }
        Thread.sleep(forTimeInterval: 10)
        return false
    }
}

/// The save test checks the file's tags as well as the model values shown in the list.
struct MetadataSaveUITestDiagnostics: View {
    @State private var fileTitles = ""

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-delayed-metadata-save") {
            Text(fileTitles)
                .accessibilityIdentifier("bulkEditSavedFileTitles")
                .task { fileTitles = await MetadataEditabilityUITestFixture.savedFileTitles() }
        }
    }
}
#endif

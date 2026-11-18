import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The synchronous file operations an import runs on `FileSystemWorkQueue`. Tests replace them to observe
/// where they run or to hold one while the import waits for it.
nonisolated struct ImportFileOperations: Sendable {
    var isVideoFile: @Sendable (URL) -> Bool = Self.isVideoContent
    /// Throws when AVAudioFile cannot read the file, which rejects it from the import.
    var openAudioFile: @Sendable (URL) throws -> Void = { _ = try AVAudioFile(forReading: $0) }
    var makeBookmark: @Sendable (URL) throws -> Data = Self.managedFileBookmark

    /// Uses the file extension when the content type cannot be read.
    static func isVideoContent(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        }
        return type.conforms(to: .movie)
    }

    static func managedFileBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

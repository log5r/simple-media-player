import Foundation
import Testing
@testable import SimpleMediaPlayer

/// Managed file paths are built without asking the file system whether they name directories, and come out
/// as they did when Foundation was asked.
@MainActor
struct ManagedFilePathTests {
    @Test(arguments: ["song.wav", "movie.MOV", "noextension"])
    func managedPathsMatchTheEarlierPathsWithoutATrailingSlash(sourceName: String) {
        let mediaDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = LibraryService(mediaDirectoryURL: mediaDirectory)
        let source = URL(fileURLWithPath: "/Volumes/Source/\(sourceName)")
        let id = UUID()

        let destination = service.mediaDirectoryURL(for: source, id: id)
        let earlier = mediaDirectory.appendingPathComponent(id.uuidString).appendingPathExtension(source.pathExtension)
        #expect(destination.path == earlier.path)
        #expect(destination.absoluteString == earlier.absoluteString)
        #expect(destination.lastPathComponent == earlier.lastPathComponent)
        #expect(destination.pathExtension == source.pathExtension)
        #expect(destination.absoluteString.hasSuffix("/") == false)

        let fallback = service.fallbackMediaURL(forFileName: destination.lastPathComponent)
        #expect(fallback.path == destination.path)
        #expect(fallback.absoluteString == mediaDirectory.appendingPathComponent(destination.lastPathComponent)
            .absoluteString)
        #expect(fallback.absoluteString.hasSuffix("/") == false)
    }
}

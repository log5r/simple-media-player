import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

/// The import inspects files and creates bookmarks on `FileSystemWorkQueue`; these tests check that moving
/// that work off the main actor keeps its outcomes.
@MainActor
struct MediaImportSourceInspectionTests {
    @Test func validAudioImportsAndAudioWithUnreadableBytesIsRejectedWithoutACopy() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let valid = try fixture.makeAudio(named: "valid.wav")
        let broken = fixture.directory.appendingPathComponent("broken.wav")
        try Data(repeating: 0x5A, count: 4_096).write(to: broken)

        let summary = await fixture.service.importFiles(
            from: [valid, broken], into: fixture.context, existingItems: []
        )

        #expect(summary.createdCount == 1)
        let item = try #require(fixture.items().first)
        #expect(try fixture.items().count == 1)
        #expect(item.title == "valid")
        #expect(item.isVideo == false)
        #expect(item.duration > 0)
        #expect(try fixture.managedFiles().map(\.lastPathComponent) == [item.fileName])
        // `resolvedURL(for:)` falls back to the file name, so the bookmark is resolved on its own here.
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        var isStale = false
        let bookmarked = try URL(
            resolvingBookmarkData: item.bookmarkData, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale
        )
        #expect(bookmarked.lastPathComponent == item.fileName)
        #expect(fixture.service.lastImportErrors.count == 1)
        #expect(fixture.service.lastImportErrors.first?.hasPrefix("broken.wav:") == true)
    }

    @Test func cancelledItemCreationThrowsAndLeavesNoManagedCopy() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        let service = fixture.service
        let session = MusicLibraryMetadataProvider().makeSession()
        let fingerprint = try MediaImportFingerprint.read(from: source)

        // The task cannot start before this test suspends on the main actor, so it is cancelled from the start.
        let task = Task { @MainActor in
            _ = try await service.makeMediaItem(from: source, importFingerprint: fingerprint, musicSession: session)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.managedFiles().isEmpty)
        #expect(try fixture.items().isEmpty)
    }
}

@MainActor
private struct InspectionFixture {
    let directory: URL
    let mediaDirectory: URL
    let container: ModelContainer
    let service: LibraryService
    var context: ModelContext { container.mainContext }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        mediaDirectory = directory.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        service = LibraryService(mediaDirectoryURL: mediaDirectory)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func makeAudio(named name: String, frameCount: AVAudioFrameCount = 4_410) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try #require(buffer.floatChannelData?[0]).update(repeating: 0.1, count: Int(frameCount))
        try file.write(from: buffer)
        return url
    }

    func items() throws -> [MediaItem] { try context.fetch(FetchDescriptor<MediaItem>()) }

    func managedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
    }
}

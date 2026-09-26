import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MediaImportDeduplicationTests {
    @Test func repeatedAndRenamedFilesInOneBatchCreateOnlyOneManagedCopy() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        let renamed = fixture.directory.appendingPathComponent("renamed.wav")
        try FileManager.default.copyItem(at: source, to: renamed)

        await fixture.service.importFiles(from: [source, source, renamed], into: fixture.context, existingItems: [])

        let items = try fixture.items()
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.fileName == "\(item.id.uuidString).wav")
        #expect(item.importFingerprint == (try MediaImportFingerprint.read(from: source)))
        #expect(try fixture.managedFiles().count == 1)
        let managedURL = try #require(fixture.service.resolvedURL(for: item))
        #expect(try Data(contentsOf: managedURL) == Data(contentsOf: source))
        #expect(fixture.service.lastImportErrors.isEmpty)
        #expect(fixture.service.importCompletedFileCount == 3)
        #expect(fixture.service.importTotalFileCount == 3)
        #expect(fixture.service.importProgress == 1)
        #expect(fixture.service.isImporting == false)

        // The caller's snapshot may not yet contain the previous batch's insertion.
        await fixture.service.importFiles(from: [renamed], into: fixture.context, existingItems: [])
        #expect(try fixture.items().map(\.id) == [item.id])
        #expect(try fixture.managedFiles().count == 1)
        #expect(fixture.service.lastImportErrors.isEmpty)
    }

    @Test func sameNameAndDurationWithDifferentContentsAreBothImported() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let first = try fixture.makeAudio(named: "first/song.wav", amplitude: 0.1)
        let second = try fixture.makeAudio(named: "second/song.wav", amplitude: 0.2)

        await fixture.service.importFiles(from: [first, second], into: fixture.context, existingItems: [])

        let items = try fixture.items()
        #expect(items.count == 2)
        #expect(Set(items.map(\.duration)).count == 1)
        #expect(Set(items.compactMap(\.importFingerprint)).count == 2)
        #expect(try fixture.managedFiles().count == 2)
        #expect(fixture.service.lastImportErrors.isEmpty)
    }

    @Test func legacyManagedCopyIsRecognizedAndOnlySameSizeCandidatesAreHashed() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        let legacy = try fixture.insertLegacyCopy(of: source)
        let largerSource = try fixture.makeAudio(named: "larger.wav", frameCount: 8_820)
        let unrelated = try fixture.insertLegacyCopy(of: largerSource)

        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])

        #expect(try fixture.items().count == 2)
        #expect(try fixture.managedFiles().count == 2)
        #expect(legacy.importFingerprint == (try MediaImportFingerprint.read(from: source)))
        #expect(unrelated.importFingerprint == nil)
        #expect(fixture.service.lastImportErrors.isEmpty)
        let verificationContext = ModelContext(fixture.container)
        let persisted = try #require(
            verificationContext.fetch(FetchDescriptor<MediaItem>()).first { $0.id == legacy.id }
        )
        #expect(persisted.importFingerprint == legacy.importFingerprint)
    }

    @Test func sameSizeLegacyFileWithDifferentContentsDoesNotSuppressImport() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let oldSource = try fixture.makeAudio(named: "old/song.wav", amplitude: 0.1)
        let newSource = try fixture.makeAudio(named: "new/song.wav", amplitude: 0.2)
        let legacy = try fixture.insertLegacyCopy(of: oldSource)
        #expect(try MediaImportFingerprint.fileSize(of: oldSource) == MediaImportFingerprint.fileSize(of: newSource))

        await fixture.service.importFiles(from: [newSource], into: fixture.context, existingItems: [legacy])

        #expect(try fixture.items().count == 2)
        #expect(try fixture.managedFiles().count == 2)
        #expect(legacy.importFingerprint == (try MediaImportFingerprint.read(from: oldSource)))
        #expect(fixture.service.lastImportErrors.isEmpty)
    }

    @Test(arguments: [false, true])
    func missingManagedFileDoesNotSuppressReimport(hasFingerprint: Bool) async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        let missing = MediaItem(
            title: "Missing",
            duration: 0.1,
            isVideo: false,
            bookmarkData: Data([0xFF]),
            fileName: "missing.wav",
            importFingerprint: hasFingerprint ? try MediaImportFingerprint.read(from: source) : nil
        )
        fixture.context.insert(missing)
        try fixture.context.save()

        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [missing])

        #expect(try fixture.items().count == 2)
        #expect(try fixture.managedFiles().count == 1)
        #expect(fixture.service.lastImportErrors.isEmpty)
    }

    @Test func originalImportIdentitySurvivesChangesToManagedFileAndMetadata() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])
        let item = try #require(fixture.items().first)
        let managedURL = try #require(fixture.service.resolvedURL(for: item))
        let fingerprint = item.importFingerprint
        item.title = "Edited title"
        item.lyricsRaw = "Edited lyrics"
        try fixture.context.save()
        // Simulate a file rewrite after importing, as occurs during embedded tag editing.
        let replacement = try fixture.makeAudio(named: "replacement.wav", amplitude: 0.3)
        try Data(contentsOf: replacement).write(to: managedURL)

        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])

        #expect(try fixture.items().map(\.id) == [item.id])
        #expect(try fixture.managedFiles().count == 1)
        #expect(item.importFingerprint == fingerprint)
        #expect(item.title == "Edited title")
        #expect(item.lyricsRaw == "Edited lyrics")
        #expect(fixture.service.lastImportErrors.isEmpty)
    }

    @Test func overlappingImportRequestsShareTheUpdatedDuplicateIndex() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.makeAudio(named: "song.wav")
        let first = Task { @MainActor in
            await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])
        }
        let second = Task { @MainActor in
            await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])
        }
        await first.value
        await second.value

        #expect(try fixture.items().count == 1)
        #expect(try fixture.managedFiles().count == 1)
        #expect(fixture.service.lastImportErrors.isEmpty)
        #expect(fixture.service.isImporting == false)
    }

    @Test func reopeningLibraryPreservesImportIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("song.wav")
        try writeAudio(to: source, amplitude: 0.1, frameCount: 4_410)
        let firstID = try await importIntoDiskLibrary(directory: directory, source: source)
        let secondID = try await importIntoDiskLibrary(directory: directory, source: source)

        #expect(secondID == firstID)
        let managedFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Media"), includingPropertiesForKeys: nil
        )
        #expect(managedFiles.count == 1)
    }

    private func importIntoDiskLibrary(directory: URL, source: URL) async throws -> UUID {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(
            schema: schema, url: directory.appendingPathComponent("library.store"), cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let service = LibraryService(mediaDirectoryURL: directory.appendingPathComponent("Media"))
        await service.importFiles(from: [source], into: container.mainContext, existingItems: [])
        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        #expect(items.count == 1)
        #expect(service.lastImportErrors.isEmpty)
        let item = try #require(items.first)
        #expect(item.importFingerprint == (try MediaImportFingerprint.read(from: source)))
        return item.id
    }
}

@MainActor
private struct ImportFixture {
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

    func makeAudio(named name: String, amplitude: Float = 0.1, frameCount: AVAudioFrameCount = 4_410) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAudio(to: url, amplitude: amplitude, frameCount: frameCount)
        return url
    }

    func insertLegacyCopy(of source: URL) throws -> MediaItem {
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        try FileManager.default.copyItem(at: source, to: mediaDirectory.appendingPathComponent(fileName))
        let item = MediaItem(
            id: id, title: "Legacy", duration: 0.1, isVideo: false, bookmarkData: Data([0xFF]), fileName: fileName
        )
        context.insert(item)
        try context.save()
        return item
    }

    func items() throws -> [MediaItem] { try context.fetch(FetchDescriptor<MediaItem>()) }

    func managedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
    }
}

private func writeAudio(to url: URL, amplitude: Float, frameCount: AVAudioFrameCount) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let samples = try #require(buffer.floatChannelData?[0])
    samples.update(repeating: amplitude, count: Int(frameCount))
    try file.write(from: buffer)
}

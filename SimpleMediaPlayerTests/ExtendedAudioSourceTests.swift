import AVFoundation
import Foundation
import SFBAudioEngine
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@Suite(.serialized)
struct ExtendedAudioSourceTests {
    @Test(arguments: [
        ("wma", ExtendedAudioSource.Kind.wma, "Fixture WMA"),
        ("wv", ExtendedAudioSource.Kind.wavPack, "Fixture WavPack")
    ])
    func decodesAndCachesOriginal(ext: String, kind: ExtendedAudioSource.Kind, title: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.\(ext)")
        try FileManager.default.copyItem(at: fixture(ext), to: source)
        defer { ExtendedAudioSource.removeCache(for: source) }
        let original = try Data(contentsOf: source)

        #expect(try ExtendedAudioSource.kind(for: source) == kind)
        let info = try ExtendedAudioSource.info(for: source, kind: kind)
        #expect(info.title == title)
        #expect(info.duration > 0.8 && info.duration < 1.2)
        #expect(info.sampleRate == 44_100)
        if kind == .wavPack {
            let fileSize = try #require(FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int)
            let estimatedKbps = Double(fileSize) * 8 / info.duration / 1_000
            let bitrate = try #require(info.bitrateKbps)
            #expect(Double(bitrate) > estimatedKbps / 2)
            #expect(Double(bitrate) < estimatedKbps * 2)
        }
        if kind == .wma {
            #expect(info.artist == "Fixture Artist")
            #expect(info.album == "Fixture Album")
            #expect(info.lyrics == "Fixture lyrics")
        }

        let cached = try ExtendedAudioSource.readableFile(for: source)
        defer { cached.release() }
        let cacheURL = cached.url
        #expect(cacheURL.pathExtension == "caf")
        let reused = try ExtendedAudioSource.readableFile(for: source)
        defer { reused.release() }
        #expect(reused.url == cacheURL)
        let audio = try AVAudioFile(forReading: cacheURL)
        #expect(audio.length > 40_000)
        #expect(try Data(contentsOf: source) == original)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: source.path
        )
        let refreshed = try ExtendedAudioSource.readableFile(for: source)
        defer { refreshed.release() }
        let refreshedURL = refreshed.url
        #expect(refreshedURL != cacheURL)
        #expect(try AVAudioFile(forReading: refreshedURL).length > 40_000)
        ExtendedAudioSource.removeCache(for: source)
        cached.release()
        reused.release()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    @Test func decodesShortWMA() throws {
        let source = fixture("wma", baseName: "short-wma")
        defer { ExtendedAudioSource.removeCache(for: source) }
        #expect(try ExtendedAudioSource.kind(for: source) == .wma)
        try ExtendedAudioSource.validate(for: source)
        let cached = try ExtendedAudioSource.readableFile(for: source)
        defer { cached.release() }
        #expect(try AVAudioFile(forReading: cached.url).length > 0)
    }

    @Test func refusesMismatchedHeaderAndCleansCancelledWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appendingPathComponent("broken.wma")
        try Data("not Windows Media Audio".utf8).write(to: broken)
        #expect(throws: (any Error).self) { try ExtendedAudioSource.kind(for: broken) }

        let source = directory.appendingPathComponent("source.wv")
        try FileManager.default.copyItem(at: fixture("wv"), to: source)
        defer { ExtendedAudioSource.removeCache(for: source) }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ExtendedAudioSource.readableFile(for: source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func decodesMonkeyAudio() throws {
        let source = fixture("ape")
        #expect(try ExtendedAudioSource.kind(for: source) == .monkeysAudio)
        let info = try ExtendedAudioSource.info(for: source, kind: .monkeysAudio)
        #expect(info.duration > 0)
        defer { ExtendedAudioSource.removeCache(for: source) }
        let cached = try ExtendedAudioSource.readableFile(for: source)
        defer { cached.release() }
        let audio = try AVAudioFile(forReading: cached.url)
        #expect(audio.length > 0)
    }

    @Test func decodesMusepack() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mpc")
        defer {
            ExtendedAudioSource.removeCache(for: source)
            try? FileManager.default.removeItem(at: source)
        }
        let wav = fixture("wav", baseName: "tag-test")
        try AudioConverter.convert(wav, to: source)
        #expect(try ExtendedAudioSource.kind(for: source) == .musepack)
        let info = try ExtendedAudioSource.info(for: source, kind: .musepack)
        #expect(info.duration > 0)
        let cached = try ExtendedAudioSource.readableFile(for: source)
        defer { cached.release() }
        let audio = try AVAudioFile(forReading: cached.url)
        #expect(audio.length > 0)
    }

    @Test func decodesAPEAndMusepackWithLeadingID3v2Tag() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let musepack = directory.appendingPathComponent("original.mpc")
        try AudioConverter.convert(fixture("wav", baseName: "tag-test"), to: musepack)
        let sources: [ExtendedAudioSource.Kind: URL] = [
            .monkeysAudio: fixture("ape"),
            .musepack: musepack
        ]
        let id3v2Tag = Data([0x49, 0x44, 0x33, 0x03, 0, 0, 0, 0, 1, 2])
            + Data(repeating: 0, count: 130)
        for (kind, original) in sources {
            let source = directory.appendingPathComponent("tagged.\(original.pathExtension)")
            try (id3v2Tag + Data(contentsOf: original)).write(to: source)
            defer { ExtendedAudioSource.removeCache(for: source) }
            #expect(try ExtendedAudioSource.kind(for: source) == kind)
            let info = try ExtendedAudioSource.info(for: source, kind: kind)
            #expect(info.duration > 0)
            let cached = try ExtendedAudioSource.readableFile(for: source)
            defer { cached.release() }
            #expect(try AVAudioFile(forReading: cached.url).length > 0)
        }
    }

    @MainActor
    @Test(arguments: [("wma", "Fixture WMA"), ("wv", "Fixture WavPack")])
    func importsAndExportsOriginal(ext: String, title: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = fixture(ext)
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let service = LibraryService(mediaDirectoryURL: directory.appendingPathComponent("Managed"))
        await service.importFiles(from: [source], into: container.mainContext, existingItems: [])
        #expect(service.lastImportErrors.isEmpty)

        let item = try #require(container.mainContext.fetch(FetchDescriptor<MediaItem>()).first)
        let managed = service.fallbackMediaURL(forFileName: item.fileName)
        let cache = try #require(ExtendedAudioSource.cacheURL(for: managed))
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
        #expect(item.title == title)
        #expect(item.duration > 0.8 && item.duration < 1.2)
        if ext == "wma" { #expect(item.lyricsRaw == "Fixture lyrics") }
        let plan = try await service.makeExportPlan(for: [item])
        #expect(plan.files.first?.embeddedTitle == title)
        if ext == "wma" { #expect(plan.files.first?.albumName == "Fixture Album") }
        let exportDirectory = directory.appendingPathComponent("Export")
        let exported = await service.export(files: plan.resolvedFiles(nameOverrides: [:]), to: exportDirectory)
        #expect(exported.exportedCount == 1)
        #expect(exported.errors.isEmpty)
        let files = try #require(FileManager.default.enumerator(at: exportDirectory,
            includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL])
        let exportedFile = try #require(files.first {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        })
        #expect(try Data(contentsOf: exportedFile) == Data(contentsOf: source))
    }

    @MainActor
    @Test(arguments: ["wma", "wv"])
    func loadsMediaInfoForExtendedAudio(ext: String) async throws {
        let source = fixture(ext)
        let item = MediaItem(
            title: "Audio", duration: 1, isVideo: false,
            bookmarkData: Data(), fileName: source.lastPathComponent
        )
        let details = await MediaInfoInspector.loadDetails(for: MediaInfoItemSnapshot(item: item), url: source)
        #expect(details.errorMessage == nil)
        let rows = try #require(details.sections.first?.rows)
        #expect(rows.contains { $0.id == "codec" && $0.value.isEmpty == false })
    }

    @MainActor
    @Test func editedExtendedArtworkUsesLibraryValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("artwork.wv")
        try FileManager.default.copyItem(at: fixture("wv"), to: source)
        let embeddedArtwork = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9TewAAAABJRU5ErkJggg=="))
        let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: source)
        audioFile.metadata.attachPicture(AttachedPicture(imageData: embeddedArtwork, type: .frontCover))
        try audioFile.writeMetadata()
        #expect(try ExtendedAudioSource.info(for: source, kind: .wavPack).artworkData == embeddedArtwork)

        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let service = LibraryService(mediaDirectoryURL: directory)
        let item = MediaItem(
            title: "Fixture WavPack", duration: 1, isVideo: false,
            bookmarkData: Data([0xFF]), artworkData: embeddedArtwork, fileName: source.lastPathComponent
        )
        container.mainContext.insert(item)

        let replacement = Data([1, 2, 3])
        var draft = try await service.editableMetadataDraft(for: item)
        draft.artworkData = replacement
        draft.editsArtwork = true
        try await service.updateEmbeddedMetadata(for: item, draft: draft, in: container.mainContext)
        #expect((try await service.editableMetadataDraft(for: item)).artworkData == replacement)

        draft.artworkData = nil
        try await service.updateEmbeddedMetadata(for: item, draft: draft, in: container.mainContext)
        #expect((try await service.editableMetadataDraft(for: item)).artworkData == nil)
    }

    @Test(arguments: ["wma", "wv"])
    func transformedExportUsesDecodedAudio(ext: String) throws {
        let source = fixture(ext)
        defer { ExtendedAudioSource.removeCache(for: source) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try TransformedAudioRenderer().render(
            sourceURL: source, pitchCents: 0, rate: 1, maxSampleRate: nil,
            makeEncoder: { format in
                try CoreAudioFileEncoder(outputURL: destination, format: .wav, processingFormat: format)
            },
            progress: { _ in }
        )
        #expect(result.duration > 0)
        #expect(try AVAudioFile(forReading: destination).length > 0)
    }

    private func fixture(_ ext: String, baseName: String = "extended-test") -> URL {
        if let bundled = Bundle.allBundles.compactMap({
            $0.url(forResource: baseName, withExtension: ext)
        }).first {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(baseName).\(ext)")
    }
}

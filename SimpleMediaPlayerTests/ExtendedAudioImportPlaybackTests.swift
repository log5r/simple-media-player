import AVFoundation
import Foundation
import SFBAudioEngine
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.serialized)
struct ExtendedAudioImportPlaybackTests {
    @Test func cachedAudioLoadsAndPlaysDuringActualBulkImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try makeUniqueSources(in: directory)
        let playbackSource = directory.appendingPathComponent("playback.wma")
        try FileManager.default.copyItem(at: fixture("wma"), to: playbackSource)
        let cached = try await Task.detached { try ExtendedAudioSource.readableFile(for: playbackSource) }.value
        cached.release()
        defer { ExtendedAudioSource.removeCache(for: playbackSource) }
        let container = try makeModelContainer()
        let service = LibraryService(mediaDirectoryURL: directory.appendingPathComponent("Managed"))
        let analyzer = SpectrumAnalyzer()
        let engine = try await makePlaybackEngine(analyzer: analyzer)
        defer { engine.suspend() }

        var loadedDuringImport = false
        var playedDuringImport = false
        var playbackErrors: [String] = []
        engine.onFormatLoaded = { duration, _ in loadedDuringImport = duration > 0 && service.isImporting }
        engine.onError = { playbackErrors.append($0) }
        analyzer.onFrame = { frame in
            if frame.isPlaying && frame.currentTime > 0 && service.isImporting { playedDuringImport = true }
        }
        let importing = Task {
            await service.importFiles(from: sources, into: container.mainContext, existingItems: [])
        }
        let clock = ContinuousClock()
        let startDeadline = clock.now.advanced(by: .seconds(5))
        while service.importCompletedFileCount == 0 && clock.now < startDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(service.isImporting && service.importProgress < 1)
        engine.load(url: playbackSource)
        analyzer.setPlaybackActive(true, currentTime: 0)
        engine.play()
        let playbackDeadline = clock.now.advanced(by: .seconds(5))
        while !playedDuringImport && playbackErrors.isEmpty && service.isImporting
            && clock.now < playbackDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(loadedDuringImport)
        #expect(playedDuringImport)
        #expect(playbackErrors.isEmpty)
        engine.suspend()
        analyzer.setPlaybackActive(false, currentTime: 0)
        await importing.value
        #expect(service.lastImportErrors.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<MediaItem>()) == sources.count)
        await deactivateAudioSession()
        try expectNoManagedCaches(for: service, context: container.mainContext)
    }

    private func expectNoManagedCaches(for service: LibraryService, context: ModelContext) throws {
        for item in try context.fetch(FetchDescriptor<MediaItem>()) {
            let source = service.fallbackMediaURL(forFileName: item.fileName)
            let cache = try #require(ExtendedAudioSource.cacheURL(for: source))
            #expect(FileManager.default.fileExists(atPath: cache.path) == false)
        }
    }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makePlaybackEngine(analyzer: SpectrumAnalyzer) async throws -> AudioEngineService {
        #if os(iOS)
        try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        }.value
        #endif
        let engine = AudioEngineService(analyzer: analyzer)
        engine.setVolume(0)
        return engine
    }

    private func deactivateAudioSession() async {
        #if os(iOS)
        _ = await Task.detached {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }.value
        #endif
    }

    private func makeUniqueSources(in directory: URL) throws -> [URL] {
        try (0..<256).map { index in
            let source = directory.appendingPathComponent("import-\(index).wv")
            try FileManager.default.copyItem(at: fixture("wv"), to: source)
            let audio = try AudioFile(readingPropertiesAndMetadataFrom: source)
            audio.metadata.title = "Import \(index)"
            try audio.writeMetadata()
            return source
        }
    }

    private func fixture(_ ext: String) -> URL {
        if let bundled = Bundle.allBundles.compactMap({
            $0.url(forResource: "extended-test", withExtension: ext)
        }).first {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/extended-test.\(ext)")
    }
}

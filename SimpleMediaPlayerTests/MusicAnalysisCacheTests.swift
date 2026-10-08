import Foundation
import Testing
@testable import SimpleMediaPlayer

struct MusicAnalysisCacheTests {
    @Test func embeddedTagSaveKeepsTheAnalysisCacheHit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lyrics.flac")
        try FileManager.default.copyItem(at: fixture("tag-test.flac"), to: url)
        let original = try #require(MusicAnalysisCache.entryURL(for: url))
        defer { try? FileManager.default.removeItem(at: original) }
        MusicAnalysisCache.write(MusicAnalysis(duration: 8, bpm: 128), at: original)

        // Writers reach the default directory, as they do when saving in the app.
        try FLACMetadataWriter.write(
            MediaMetadataEditDraft(
                title: "", artist: "", album: "", genre: "", lyrics: "New lyrics",
                editsTextMetadata: false, editsLyrics: true
            ),
            to: url
        )

        let moved = try #require(MusicAnalysisCache.entryURL(for: url))
        defer { try? FileManager.default.removeItem(at: moved) }
        #expect(moved != original)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        guard #available(macOS 27, iOS 27, *) else { return }
        let service = MusicAnalysisService(readableFile: { _ in
            Issue.record("A tag-only save must not trigger reanalysis")
            throw CancellationError()
        })
        #expect(try await service.analyze(url: url).bpm == 128)
    }

    @Test func outsideChangesDoNotInheritTheCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let url = directory.appendingPathComponent("song.flac")
        try FileManager.default.copyItem(at: fixture("tag-test.flac"), to: url)
        let original = try #require(MusicAnalysisCache.entryURL(for: url, in: cache))
        MusicAnalysisCache.write(MusicAnalysis(duration: 8, bpm: 128), at: original)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let changed = try #require(MusicAnalysisCache.entryURL(for: url, in: cache))
        #expect(changed != original)
        #expect(MusicAnalysisCache.read(at: changed) == nil)
        #expect(MusicAnalysisCache.read(at: original)?.bpm == 128)
    }

    @Test func failedRewriteKeepsTheOriginalEntry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let url = directory.appendingPathComponent("song.flac")
        try FileManager.default.copyItem(at: fixture("tag-test.flac"), to: url)
        let original = try #require(MusicAnalysisCache.entryURL(for: url, in: cache))
        MusicAnalysisCache.write(MusicAnalysis(duration: 8, bpm: 128), at: original)

        #expect(throws: CocoaError.self) {
            try MediaFileRewriter.rewrite(at: url, analysisCacheDirectory: cache) { _, output, _ in
                try output.write(contentsOf: Data([1, 2, 3]))
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(MusicAnalysisCache.entryURL(for: url, in: cache) == original)
        #expect(MusicAnalysisCache.read(at: original)?.bpm == 128)
    }

    @Test(.timeLimit(.minutes(1)))
    func extendedDecodeLeavesTheActorAvailableAndReleasesCancelledFiles() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = BlockingDecoder()
        let service = MusicAnalysisService(cacheDirectory: directory, readableFile: decoder.decode)
        let task = Task { try await service.analyze(url: directory.appendingPathComponent("first.ape")) }
        await decoder.waitUntilStarted()
        // Before the fix this waited for the decode to finish.
        let display = await service.displayData(for: MusicAnalysis(duration: 2, beats: [0, 0.5, 1]))
        #expect(display.tempo == [nil, 120, 120])
        task.cancel()
        decoder.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(decoder.releaseCount == 1)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func switchingAwayFromAnExtendedDecodeShowsTheNextTrackFirst() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let second = directory.appendingPathComponent("second.flac")
        try FileManager.default.copyItem(at: fixture("tag-test.flac"), to: second)
        let entry = try #require(MusicAnalysisCache.entryURL(for: second, in: cache))
        MusicAnalysisCache.write(MusicAnalysis(duration: 8, bpm: 140), at: entry)
        let decoder = BlockingDecoder()
        let service = MusicAnalysisService(cacheDirectory: cache, readableFile: decoder.decode)
        let controller = MusicAnalysisController(analyzeWithProgress: { url, progress in
            try await service.analyze(url: url, onProgress: progress)
        })

        let first = controller.load(url: directory.appendingPathComponent("first.ape"))
        await decoder.waitUntilStarted()
        let next = controller.load(url: second)
        await next?.value
        #expect(controller.status == .ready)
        #expect(controller.result?.bpm == 140)

        decoder.finish()
        await first?.value
        #expect(controller.status == .ready)
        #expect(controller.result?.bpm == 140)
        #expect(decoder.releaseCount == 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicAnalysisCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }
}

/// Blocks a worker thread like a whole-song decode until the test finishes it.
private nonisolated final class BlockingDecoder: @unchecked Sendable {
    private let condition = NSCondition()
    private var isFinished = false
    private var releases = 0
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    var releaseCount: Int { condition.withLock { releases } }

    func decode(_ url: URL) -> ExtendedAudioCache.ReadableFile {
        startedContinuation.yield()
        condition.withLock {
            while !isFinished { condition.wait() }
        }
        return ExtendedAudioCache.ReadableFile(url: url) { [self] in
            condition.withLock { releases += 1 }
        }
    }

    func waitUntilStarted() async {
        for await _ in started { return }
    }

    func finish() {
        condition.withLock {
            isFinished = true
            condition.broadcast()
        }
    }
}

import Foundation
import Testing
@testable import SimpleMediaPlayer

/// A tag save or a removal that finishes while a file is analyzed must not leave the analysis at the old key,
/// where no lookup could find it again.
struct MusicAnalysisStoreRaceTests {
    @Test(arguments: FileChange.allCases, ChangeMoment.allCases)
    func changeBeforeTheWriteLeavesNoUnreachableEntry(change: FileChange, moment: ChangeMoment) async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let url = try makeFile(in: directory)
        let original = try #require(MusicAnalysisCache.entryURL(for: url, in: cache))
        let service = makeService(cache: cache) {
            if moment == .duringAnalysis { try change.apply(to: url, cache: cache) }
            return MusicAnalysis(duration: 8, bpm: 128)
        }

        let analysis = try await FileAttributeCacheKey.$willStore.withValue({
            if moment == .betweenCheckAndWrite { try? change.apply(to: url, cache: cache) }
        }, operation: {
            try await service.analyze(url: url)
        })

        #expect(analysis.bpm == 128)
        #expect(FileManager.default.fileExists(atPath: original.path) == false)
        #expect(try entryNames(in: cache).isEmpty)
        if change != .removal {
            // The changed file was never analyzed, so the next lookup analyzes it.
            let changed = try #require(MusicAnalysisCache.entryURL(for: url, in: cache))
            #expect(MusicAnalysisCache.read(at: changed) == nil)
        }
    }

    /// A save that runs after the write moves the entry, so the analysis still matches the saved file.
    @Test(arguments: [FileChange.inPlaceSave, .replacingSave])
    func saveAfterTheWriteCarriesTheEntry(change: FileChange) async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let url = try makeFile(in: directory)

        _ = try await makeService(cache: cache) { MusicAnalysis(duration: 8, bpm: 128) }.analyze(url: url)
        try change.apply(to: url, cache: cache)

        #expect(try entryNames(in: cache).count == 1)
        let service = makeService(cache: cache) {
            Issue.record("A tag-only save must not trigger reanalysis")
            throw CancellationError()
        }
        #expect(try await service.analyze(url: url).bpm == 128)
    }

    enum FileChange: CaseIterable, Sendable {
        case inPlaceSave
        case replacingSave
        case removal

        func apply(to url: URL, cache: URL) throws {
            switch self {
            case .inPlaceSave:
                try MediaFileRewriter.update(
                    at: url, analysisCacheDirectory: cache, loudnessCacheDirectory: nil
                ) { _, _ in
                    MediaFileRewriter.InPlaceEdit(offset: 0, originalLength: 4, data: Data("TAGS".utf8))
                } rewrite: { _, _, _ in
                    Issue.record("The edit fits in place")
                }
            case .replacingSave:
                try MediaFileRewriter.rewrite(
                    at: url, analysisCacheDirectory: cache, loudnessCacheDirectory: nil
                ) { source, output, size in
                    try output.write(contentsOf: Data("TAGS".utf8))
                    try MediaFileRewriter.copy(from: source, range: 4..<size, to: output)
                }
            case .removal:
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    enum ChangeMoment: CaseIterable, Sendable {
        case duringAnalysis
        case betweenCheckAndWrite
    }

    /// A service that analyzes without waiting, reads the file in place, and returns `analyze()` as the analysis.
    private func makeService(
        cache: URL, analyze: @escaping @Sendable () throws -> MusicAnalysis
    ) -> MusicAnalysisService {
        MusicAnalysisService(
            cacheDirectory: cache,
            readableFile: { ExtendedAudioCache.ReadableFile(url: $0) },
            waitBeforeAnalyzing: {},
            analyzeReadableFile: { _ in try analyze() }
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicAnalysisStoreRaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small file with a modification date in the past, so any later write changes it.
    private func makeFile(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("song.caf")
        try Data("RIFFaudio".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: url.path
        )
        return url
    }

    private func entryNames(in cache: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: cache.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: cache.path)
    }
}

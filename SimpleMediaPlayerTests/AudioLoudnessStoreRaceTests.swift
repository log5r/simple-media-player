import Foundation
import Testing
@testable import SimpleMediaPlayer

/// A tag save or a removal that finishes while a file is measured must not leave the gain at the old key,
/// where no lookup could find it again.
struct AudioLoudnessStoreRaceTests {
    @Test(arguments: FileChange.allCases, ChangeMoment.allCases)
    func changeBeforeTheWriteLeavesNoUnreachableEntry(change: FileChange, moment: ChangeMoment) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let url = try makeFile(in: directory)
        let original = try #require(AudioLoudnessCache.entryURL(for: url, in: cache))

        let gain = try AudioLoudnessCache.$willStore.withValue({
            if moment == .betweenCheckAndWrite { try? change.apply(to: url, cache: cache) }
        }, operation: {
            try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, cacheDirectory: cache) { _ in
                if moment == .duringMeasurement { try change.apply(to: url, cache: cache) }
                return 4.5
            }
        })

        #expect(gain == 4.5)
        #expect(FileManager.default.fileExists(atPath: original.path) == false)
        #expect(try entryNames(in: cache).isEmpty)
        if change != .removal {
            // The changed file was never measured, so the next lookup measures it.
            #expect(AudioLoudnessNormalizer.cachedGain(for: url, cacheDirectory: cache) == nil)
        }
    }

    /// A save that runs after the write moves the entry, so the gain still matches the saved file.
    @Test(arguments: [FileChange.inPlaceSave, .replacingSave])
    func saveAfterTheWriteCarriesTheEntry(change: FileChange) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let url = try makeFile(in: directory)

        _ = try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, cacheDirectory: cache) { _ in 4.5 }
        try change.apply(to: url, cache: cache)

        #expect(try entryNames(in: cache).count == 1)
        #expect(AudioLoudnessNormalizer.cachedGain(for: url, cacheDirectory: cache) == 4.5)
    }

    /// Ending a transient session does not wait for its loudness measurement. A measurement that passed its
    /// last cancellation check writes after the cleanup has removed the files and their entries.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func transientCleanupBeforeTheWriteLeavesNoEntry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let sessionDirectory = directory.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let item = MediaItem(
            title: "One", duration: 1, isVideo: false, bookmarkData: Data(), fileName: "One.wav",
            musicLibraryItemID: "One"
        )
        let session = TransientPlaybackSession(
            directory: sessionDirectory, items: [item], analysisCacheDirectory: nil, loudnessCacheDirectory: cache
        )
        let url = sessionDirectory.appendingPathComponent("One.wav")
        try Data("RIFFaudio".utf8).write(to: url)
        let gate = StoreGate()

        // The gate blocks a dispatch worker, as measurement does, not a cooperative thread.
        let measurement = Task.detached(executorPreference: BlockingWorkExecutor.shared) {
            try AudioLoudnessCache.$willStore.withValue({ gate.reachAndWait() }, operation: {
                try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, cacheDirectory: cache) { _ in 4.5 }
            })
        }
        await gate.waitUntilReached()
        session.end()
        await session.awaitCleanup()
        gate.open()

        #expect(try await measurement.value == 4.5)
        #expect(FileManager.default.fileExists(atPath: sessionDirectory.path) == false)
        #expect(try entryNames(in: cache).isEmpty)
    }

    enum FileChange: CaseIterable, Sendable {
        case inPlaceSave
        case replacingSave
        case removal

        func apply(to url: URL, cache: URL) throws {
            switch self {
            case .inPlaceSave:
                try MediaFileRewriter.update(
                    at: url, analysisCacheDirectory: nil, loudnessCacheDirectory: cache
                ) { _, _ in
                    MediaFileRewriter.InPlaceEdit(offset: 0, originalLength: 4, data: Data("TAGS".utf8))
                } rewrite: { _, _, _ in
                    Issue.record("The edit fits in place")
                }
            case .replacingSave:
                try MediaFileRewriter.rewrite(
                    at: url, analysisCacheDirectory: nil, loudnessCacheDirectory: cache
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
        case duringMeasurement
        case betweenCheckAndWrite
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioLoudnessStoreRaceTests-\(UUID().uuidString)", isDirectory: true)
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

/// Holds the store between its key check and its write until the test has changed the file.
private nonisolated final class StoreGate: @unchecked Sendable {
    private let reached: AsyncStream<Void>
    private let reachedContinuation: AsyncStream<Void>.Continuation
    private let release = DispatchSemaphore(value: 0)

    init() {
        (reached, reachedContinuation) = AsyncStream.makeStream()
    }

    func reachAndWait() {
        reachedContinuation.yield()
        release.wait()
    }

    func waitUntilReached() async {
        for await _ in reached { return }
    }

    func open() {
        release.signal()
    }
}

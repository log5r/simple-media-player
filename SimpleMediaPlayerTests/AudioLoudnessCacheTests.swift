import Foundation
import Testing
@testable import SimpleMediaPlayer

struct AudioLoudnessCacheTests {
    /// The earlier cache kept 256 gains and evicted by path order, so cycling a larger library measured again.
    @Test func everyFileOfALargeLibraryStaysCached() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let urls = try (0..<300).map { try fixture.makeFile(named: "track-\($0).caf") }

        var measuredCount = 0
        for (index, url) in urls.enumerated() {
            let gain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, cacheDirectory: fixture.cache) { _ in
                measuredCount += 1
                return Float(index) / 100
            }
            #expect(gain == Float(index) / 100)
        }
        for (index, url) in urls.enumerated() {
            let gain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, cacheDirectory: fixture.cache) { _ in
                Issue.record("A cached file was measured again.")
                return 0
            }
            #expect(gain == Float(index) / 100)
        }

        #expect(measuredCount == urls.count)
    }

    @Test(arguments: [false, true])
    func tagSaveCarriesTheGainToTheRewrittenFile(inPlace: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.makeFile(named: "song.caf")
        try fixture.storeGain(4.5, for: url)
        let original = try #require(AudioLoudnessCache.entryURL(for: url, in: fixture.cache))

        if inPlace {
            try MediaFileRewriter.update(
                at: url, analysisCacheDirectory: nil, loudnessCacheDirectory: fixture.cache
            ) { _, _ in
                MediaFileRewriter.InPlaceEdit(offset: 0, originalLength: 4, data: Data("TAGS".utf8))
            } rewrite: { _, _, _ in
                Issue.record("The edit fits in place")
            }
        } else {
            try MediaFileRewriter.rewrite(
                at: url, analysisCacheDirectory: nil, loudnessCacheDirectory: fixture.cache
            ) { source, output, size in
                try output.write(contentsOf: Data("TAGS".utf8))
                try MediaFileRewriter.copy(from: source, range: 4..<size, to: output)
            }
        }

        #expect(AudioLoudnessCache.entryURL(for: url, in: fixture.cache) != original)
        #expect(FileManager.default.fileExists(atPath: original.path) == false)
        #expect(try fixture.entryNames().count == 1)
        let gain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, cacheDirectory: fixture.cache) { _ in
            Issue.record("A tag-only save must not trigger another measurement.")
            return 0
        }
        #expect(gain == 4.5)
    }

    /// Saves through the app's writers reach the default directory, as they do in the app.
    @Test(arguments: [false, true])
    func writerSaveKeepsTheGainInTheDefaultCache(allowsInPlaceEdits: Bool) throws {
        let fixture = try InPlaceTestFormat.flac.preparedFixture()
        defer { fixture.remove() }
        let original = try #require(AudioLoudnessCache.entryURL(for: fixture.url))
        defer { try? FileManager.default.removeItem(at: original) }
        AudioLoudnessCache.write(-3.25, at: original)
        let fileNumber = try fixture.fileNumber()

        try MediaFileRewriter.$allowsInPlaceEdits.withValue(allowsInPlaceEdits) {
            try InPlaceTestFormat.flac.write(titleDraft("Short"), to: fixture.url)
        }

        let moved = try #require(AudioLoudnessCache.entryURL(for: fixture.url))
        defer { try? FileManager.default.removeItem(at: moved) }
        // A replacement gives the path a new file; an in-place edit keeps it.
        #expect(try (fixture.fileNumber() == fileNumber) == allowsInPlaceEdits)
        #expect(moved != original)
        #expect(FileManager.default.fileExists(atPath: original.path) == false)
        #expect(AudioLoudnessNormalizer.cachedGain(for: fixture.url) == -3.25)
    }

    @Test(arguments: [false, true], RewriteInterruption.allCases)
    func interruptedSaveLeavesTheGainAtTheOriginalKey(inPlace: Bool, interruption: RewriteInterruption) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.makeFile(named: "song.caf")
        let contents = try Data(contentsOf: url)
        try fixture.storeGain(4.5, for: url)
        let original = try #require(AudioLoudnessCache.entryURL(for: url, in: fixture.cache))
        let cache = fixture.cache

        let save: @Sendable () throws -> Void = {
            if inPlace {
                try MediaFileRewriter.update(
                    at: url, analysisCacheDirectory: nil, loudnessCacheDirectory: cache
                ) { _, _ in
                    MediaFileRewriter.InPlaceEdit(offset: 0, originalLength: 4, data: Data("TAGS".utf8))
                } rewrite: { _, _, _ in
                    Issue.record("The edit fits in place")
                }
            } else {
                try MediaFileRewriter.rewrite(
                    at: url, analysisCacheDirectory: nil, loudnessCacheDirectory: cache
                ) { _, output, _ in
                    try output.write(contentsOf: Data("TAGS".utf8))
                    throw InjectedWriteError()
                }
            }
        }
        let result = await Task.detached {
            switch interruption {
            case .writeFails:
                try MediaFileRewriter.$inPlaceWrite.withValue({ handle, data in
                    try handle.write(contentsOf: data.prefix(2))
                    throw InjectedWriteError()
                }, operation: save)
            case .cancelledBeforeWriting:
                withUnsafeCurrentTask { $0?.cancel() }
                try save()
            }
        }.result

        switch (interruption, result) {
        case (.writeFails, .failure(let error)): #expect(error is InjectedWriteError)
        case (.cancelledBeforeWriting, .failure(let error)): #expect(error is CancellationError)
        case (_, .success): Issue.record("The save unexpectedly succeeded.")
        }
        #expect(try Data(contentsOf: url) == contents)
        #expect(AudioLoudnessCache.entryURL(for: url, in: fixture.cache) == original)
        #expect(try fixture.entryNames() == [original.lastPathComponent])
        #expect(AudioLoudnessNormalizer.cachedGain(for: url, cacheDirectory: fixture.cache) == 4.5)
    }

    @Test(arguments: OutsideChange.allCases)
    func outsideChangesMissTheStoredGain(change: OutsideChange) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.makeFile(named: "song.caf")
        try fixture.storeGain(4.5, for: url)

        switch change {
        case .size:
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
        case .modificationDate:
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path
            )
        }

        #expect(AudioLoudnessNormalizer.cachedGain(for: url, cacheDirectory: fixture.cache) == nil)
        var measuredCount = 0
        let gain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, cacheDirectory: fixture.cache) { _ in
            measuredCount += 1
            return -2
        }
        #expect(gain == -2)
        #expect(measuredCount == 1)
    }

    @Test func legacyDictionaryMovesToTheFileCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let suiteName = "AudioLoudnessCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrated = try fixture.makeFile(named: "Café | song.caf")
        let kept = try fixture.makeFile(named: "kept.caf")
        let stringValue = try fixture.makeFile(named: "string.caf")
        let boolValue = try fixture.makeFile(named: "bool.caf")
        let badDate = try fixture.makeFile(named: "date.caf")
        try fixture.storeGain(1, for: kept)
        let legacy: [String: Any] = [
            try legacyKey(for: migrated): 3.5,
            try legacyKey(for: kept): 9.0,
            try legacyKey(for: stringValue): "loud",
            try legacyKey(for: boolValue): true,
            try legacyKey(for: badDate) + "x": 2.0,
            "relative/path|10|1700000000.0": 2.0,
            "no separators": 2.0
        ]
        defaults.set(legacy, forKey: AudioLoudnessCache.legacyDefaultsKey)

        AudioLoudnessCache.migrateLegacyEntries(from: defaults, into: fixture.cache)
        // A second run finds nothing to move.
        AudioLoudnessCache.migrateLegacyEntries(from: defaults, into: fixture.cache)

        #expect(defaults.object(forKey: AudioLoudnessCache.legacyDefaultsKey) == nil)
        #expect(AudioLoudnessNormalizer.cachedGain(for: migrated, cacheDirectory: fixture.cache) == 3.5)
        #expect(AudioLoudnessNormalizer.cachedGain(for: kept, cacheDirectory: fixture.cache) == 1)
        for url in [stringValue, boolValue, badDate] {
            #expect(AudioLoudnessNormalizer.cachedGain(for: url, cacheDirectory: fixture.cache) == nil)
        }
        #expect(try fixture.entryNames().count == 2)
    }

    /// The key the earlier cache gave the file.
    private func legacyKey(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = try #require(values.fileSize)
        let modificationDate = try #require(values.contentModificationDate)
        return "\(url.path)|\(size)|\(modificationDate.timeIntervalSince1970)"
    }

    enum RewriteInterruption: CaseIterable, Sendable {
        case writeFails
        case cancelledBeforeWriting
    }

    enum OutsideChange: CaseIterable, Sendable {
        case size
        case modificationDate
    }

    private struct Fixture {
        let directory: URL
        let cache: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioLoudnessCacheTests-\(UUID().uuidString)", isDirectory: true)
            cache = directory.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        /// A small file with a modification date in the past, so any later write changes it.
        func makeFile(named name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("RIFFaudio-\(name)".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: url.path
            )
            return url
        }

        func storeGain(_ gain: Float, for url: URL) throws {
            let stored = try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, cacheDirectory: cache) { _ in gain }
            #expect(stored == gain)
        }

        func entryNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: cache.path)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct AudioLoudnessCancellationTests {
    @Test(arguments: [false, true])
    func cancellationBeforeMeasurementDoesNotReadOrChangeCache(hasCachedGain: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        if hasCachedGain {
            _ = try AudioLoudnessNormalizer.cachedOrMeasuredGain(
                for: fixture.url,
                cacheDirectory: fixture.cacheDirectory,
                measure: { _ in 3 }
            )
        }
        let previousCache = fixture.cache
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AudioLoudnessNormalizer.cachedOrMeasuredGain(
                for: fixture.url,
                cacheDirectory: fixture.cacheDirectory,
                measure: { _ in
                    Issue.record("A cancelled task unexpectedly started measuring audio.")
                    return 7
                }
            )
        }

        let result = await task.result
        #expect(isCancellation(result))
        #expect(fixture.cache == previousCache)
    }

    @Test(arguments: CancellationDuringMeasurement.allCases)
    private func interruptedMeasurementDoesNotCacheFallbackGain(
        behavior: CancellationDuringMeasurement
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = Task.detached {
            try AudioLoudnessNormalizer.cachedOrMeasuredGain(
                for: fixture.url,
                cacheDirectory: fixture.cacheDirectory,
                measure: { _ in
                    switch behavior {
                    case .throwsCancellation:
                        throw CancellationError()
                    case .cancelsThenReturns:
                        withUnsafeCurrentTask { $0?.cancel() }
                        return 7
                    case .cancelsThenFails:
                        withUnsafeCurrentTask { $0?.cancel() }
                        throw CocoaError(.fileReadUnknown)
                    }
                }
            )
        }

        let result = await task.result
        #expect(isCancellation(result))
        #expect(fixture.cache.isEmpty)

        let gain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(
            for: fixture.url, cacheDirectory: fixture.cacheDirectory
        )
        #expect(abs(gain - 2) < 0.01)
        #expect(fixture.cache.count == 1)
    }

    @Test func successfulMeasurementIsReusedFromCache() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let measuredGain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(
            for: fixture.url, cacheDirectory: fixture.cacheDirectory
        )
        let cachedGain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(
            for: fixture.url,
            cacheDirectory: fixture.cacheDirectory,
            measure: { _ in
                Issue.record("A cached audio file was unexpectedly measured again.")
                return 0
            }
        )

        #expect(abs(measuredGain - 2) < 0.01)
        #expect(cachedGain == measuredGain)
        #expect(fixture.cache.count == 1)
    }

    @Test func ordinaryMeasurementFailurePreservesZeroGainFallback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(
            for: fixture.url,
            cacheDirectory: fixture.cacheDirectory,
            measure: { _ in throw CocoaError(.fileReadCorruptFile) }
        )
        let cachedGain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(
            for: fixture.url,
            cacheDirectory: fixture.cacheDirectory,
            measure: { _ in
                Issue.record("A cached fallback was unexpectedly measured again.")
                return 5
            }
        )

        #expect(gain == 0)
        #expect(cachedGain == 0)
        #expect(fixture.cache.count == 1)
    }

    @Test func concurrentMeasurementsPreserveEveryCacheEntry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let urls = try (0..<32).map { index in
            let url = fixture.directory.appendingPathComponent("source-\(index).caf")
            try FileManager.default.copyItem(at: fixture.url, to: url)
            return url
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let gain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(
                        for: url,
                        cacheDirectory: fixture.cacheDirectory,
                        measure: { _ in Float(index) }
                    )
                    #expect(gain == Float(index))
                }
            }
            try await group.waitForAll()
        }

        #expect(fixture.cache.count == urls.count)
        #expect(Set(fixture.cache.values) == Set((0..<urls.count).map(Float.init)))
    }

    private func isCancellation<Value>(_ result: Result<Value, Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }

    private enum CancellationDuringMeasurement: CaseIterable, Sendable {
        case throwsCancellation
        case cancelsThenReturns
        case cancelsThenFails
    }

    private struct Fixture: @unchecked Sendable {
        let directory: URL
        let url: URL
        let cacheDirectory: URL

        /// The stored gains by entry name.
        var cache: [String: Float] {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory, includingPropertiesForKeys: nil
            )) ?? []
            return entries.reduce(into: [:]) { cache, entry in
                cache[entry.lastPathComponent] = AudioLoudnessCache.read(at: entry)
            }
        }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            url = directory.appendingPathComponent("source.caf")
            cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<Int(buffer.frameLength) {
                samples[index] = 0.1
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

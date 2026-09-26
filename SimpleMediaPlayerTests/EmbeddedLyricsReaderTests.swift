import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct EmbeddedLyricsReaderTests {
    @Test(arguments: ["m4a", "M4V", "mp4", "mov"])
    @MainActor func MP4LyricsSkipAssetLoadingOffMainThread(fileExtension: String) async throws {
        let reader = EmbeddedLyricsReader(
            readMP4: { _ in
                #expect(Thread.isMainThread == false)
                return " First line\nSecond line "
            },
            readAsset: { _ in throw ReaderFailure.unexpectedAssetRead }
        )

        #expect(try await reader.read(from: temporaryURL(extension: fileExtension)) == " First line\nSecond line ")
    }

    @Test(arguments: [nil, "", " \n\t"] as [String?])
    func emptyMP4LyricsFallBackToAsset(lyrics: String?) async throws {
        let reader = EmbeddedLyricsReader(readMP4: { _ in lyrics }, readAsset: { _ in "Asset lyrics" })

        #expect(try await reader.read(from: temporaryURL(extension: "m4a")) == "Asset lyrics")
    }

    @Test func failedMP4ParsingFallsBackToAsset() async throws {
        let reader = EmbeddedLyricsReader(
            readMP4: { _ in throw ReaderFailure.invalidMP4 },
            readAsset: { _ in "Asset lyrics" }
        )

        #expect(try await reader.read(from: temporaryURL(extension: "m4a")) == "Asset lyrics")
    }

    @Test(arguments: ["mp3", "aiff", "wav"])
    func otherFormatsSkipMP4Parsing(fileExtension: String) async throws {
        let reader = EmbeddedLyricsReader(
            readMP4: { _ in
                Issue.record("A non-MP4 file was sent to the MP4 reader.")
                return nil
            },
            readAsset: { _ in
                #expect(isMainThread() == false)
                return "Asset lyrics"
            }
        )

        #expect(try await reader.read(from: temporaryURL(extension: fileExtension)) == "Asset lyrics")
    }

    @Test func assetFailureAndWhitespaceAreNotLyrics() async throws {
        let failing = EmbeddedLyricsReader(readAsset: { _ in throw ReaderFailure.assetFailure })
        await #expect(throws: ReaderFailure.assetFailure) {
            try await failing.read(from: temporaryURL(extension: "wav"))
        }
        let empty = EmbeddedLyricsReader(readAsset: { _ in " \n\t" })
        #expect(try await empty.read(from: temporaryURL(extension: "wav")) == nil)
    }

    @Test func cancellationBeforeReadingSkipsBothReaders() async throws {
        let reader = EmbeddedLyricsReader(
            readMP4: { _ in throw ReaderFailure.unexpectedMP4Read },
            readAsset: { _ in throw ReaderFailure.unexpectedAssetRead }
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.read(from: temporaryURL(extension: "m4a"))
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [false, true])
    func cancellationAfterMP4ReadingSuppressesResultAndFallback(hasLyrics: Bool) async throws {
        let reader = EmbeddedLyricsReader(
            readMP4: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return hasLyrics ? "Cancelled lyrics" : nil
            },
            readAsset: { _ in throw ReaderFailure.unexpectedAssetRead }
        )

        await #expect(throws: CancellationError.self) {
            try await reader.read(from: temporaryURL(extension: "m4a"))
        }
    }

    @Test func MP4CancellationDoesNotStartFallback() async throws {
        let reader = EmbeddedLyricsReader(
            readMP4: { _ in throw CancellationError() },
            readAsset: { _ in throw ReaderFailure.unexpectedAssetRead }
        )

        await #expect(throws: CancellationError.self) {
            try await reader.read(from: temporaryURL(extension: "m4a"))
        }
    }

    @Test func parentCancellationReachesAssetReaderAndSuppressesLateResult() async throws {
        let started = AsyncStream<Void>.makeStream()
        let cancellation = CancellationObservation()
        let reader = EmbeddedLyricsReader(readAsset: { _ in
            started.continuation.yield(())
            do {
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                await cancellation.record()
            }
            return "Late lyrics"
        })
        let task = Task { try await reader.read(from: temporaryURL(extension: "mp3")) }
        for await _ in started.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cancellation.wasObserved)
        started.continuation.finish()
    }

    @Test @MainActor func readsActualM4ALyricsThroughBothMetadataPaths() async throws {
        let url = temporaryURL(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeM4A(to: url)
        let lyrics = "[00:01.00]First line\n[00:02.00]Second line"
        let draft = MediaMetadataEditDraft(
            title: "Lyrics fixture", artist: "", album: "", genre: "", lyrics: lyrics, editsLyrics: true
        )
        try MP4MetadataWriter.write(draft, to: url)

        #expect(try await EmbeddedLyricsReader().read(from: url) == lyrics)
        #expect(try await EmbeddedLyricsReader(readMP4: { _ in nil }).read(from: url) == lyrics)
    }

    @Test func untaggedAudioReturnsNilAndMissingAudioThrows() async throws {
        let url = temporaryURL(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeM4A(to: url)

        #expect(try await EmbeddedLyricsReader().read(from: url) == nil)
        await #expect(throws: (any Error).self) {
            try await EmbeddedLyricsReader().read(from: temporaryURL(extension: "m4a"))
        }
    }

    private func writeM4A(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        try file.write(from: buffer)
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }
}

private enum ReaderFailure: Error, Equatable {
    case invalidMP4
    case unexpectedMP4Read
    case unexpectedAssetRead
    case assetFailure
}

private actor CancellationObservation {
    private(set) var wasObserved = false

    func record() { wasObserved = true }
}

private func isMainThread() -> Bool { Thread.isMainThread }

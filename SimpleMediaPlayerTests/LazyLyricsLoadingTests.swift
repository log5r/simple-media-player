import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LazyLyricsLoadingTests {
    @Test func readsOnlyTheRequestedTrackAndPersistsDiscoveredLyrics() async throws {
        let probe = LyricsReadProbe()
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            await probe.record(url)
            return "Discovered lyrics"
        }))
        let items = (0..<100).map { fixture.insertItem(named: "track-\($0).wav") }
        try fixture.context.save()
        #expect(await probe.urls.isEmpty)

        await fixture.service.refreshMissingLyrics(for: items[40], in: fixture.context)

        #expect(await probe.urls == [fixture.service.resolvedURL(for: items[40])])
        #expect(items[40].lyricsRaw == "Discovered lyrics")
        #expect(items.enumerated().allSatisfy { $0.offset == 40 || $0.element.lyricsRaw == nil })
        let saved = try ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>())
        #expect(saved.first { $0.id == items[40].id }?.lyricsRaw == "Discovered lyrics")

        await fixture.service.refreshMissingLyrics(for: items[40], in: fixture.context)
        #expect(await probe.urls.count == 1)
    }

    @Test func videosAndTracksWithStoredLyricsDoNotReadFiles() async throws {
        let probe = LyricsReadProbe()
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            await probe.record(url)
            return "Embedded lyrics"
        }))
        let video = fixture.insertItem(named: "video.wav", isVideo: true)
        let edited = fixture.insertItem(named: "edited.wav", lyrics: "Application-only lyrics")
        try fixture.context.save()

        await fixture.service.refreshMissingLyrics(for: video, in: fixture.context)
        await fixture.service.refreshMissingLyrics(for: edited, in: fixture.context)

        #expect(await probe.urls.isEmpty)
        #expect(video.lyricsRaw == nil)
        #expect(edited.lyricsRaw == "Application-only lyrics")
    }

    @Test func cancelledRequestDoesNotApplyALateResult() async throws {
        let probe = ControlledLyricsRead()
        defer { Task { await probe.finishAll() } }
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            try await probe.read(url)
        }))
        let item = fixture.insertItem(named: "track.wav")
        try fixture.context.save()
        let task = Task { @MainActor in
            await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        }
        try await waitForReads(1, probe: probe)
        task.cancel()
        await probe.finish(1, lyrics: "Obsolete lyrics")
        await task.value

        #expect(item.lyricsRaw == nil)
        let saved = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>()).first)
        #expect(saved.lyricsRaw == nil)
    }

    @Test func alreadyCancelledRequestDoesNotReadFiles() async throws {
        let probe = LyricsReadProbe()
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            await probe.record(url)
            return "Embedded lyrics"
        }))
        let item = fixture.insertItem(named: "track.wav")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        }
        await task.value

        #expect(await probe.urls.isEmpty)
        #expect(item.lyricsRaw == nil)
    }

    @Test(arguments: ["User's replacement lyrics", ""])
    func editingOrClearingLyricsInvalidatesAnInFlightRead(editedLyrics: String) async throws {
        let probe = ControlledLyricsRead()
        defer { Task { await probe.finishAll() } }
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            try await probe.read(url)
        }))
        let item = fixture.insertItem(named: "track.wav")
        try fixture.context.save()
        let task = Task { @MainActor in
            await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        }
        try await waitForReads(1, probe: probe)

        try await fixture.service.saveLyrics(editedLyrics, for: item, embedInFile: false, in: fixture.context)
        await probe.finish(1, lyrics: "Obsolete embedded lyrics")
        await task.value

        let expected = editedLyrics.isEmpty ? nil : editedLyrics
        #expect(item.lyricsRaw == expected)
        let saved = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>()).first)
        #expect(saved.lyricsRaw == expected)
    }

    @Test(arguments: ["User's replacement lyrics", ""])
    func savedAppOnlyLyricsArePreservedWhenThePanelReopens(editedLyrics: String) async throws {
        let probe = LyricsReadProbe()
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            await probe.record(url)
            return "Original embedded lyrics"
        }))
        let item = fixture.insertItem(named: "track.wav", lyrics: "Original embedded lyrics")
        try fixture.context.save()
        try await fixture.service.saveLyrics(editedLyrics, for: item, embedInFile: false, in: fixture.context)

        await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)

        #expect(await probe.urls.isEmpty)
        #expect(item.lyricsRaw == (editedLyrics.isEmpty ? nil : editedLyrics))
    }

    @Test func aNewRequestSupersedesAnOlderReadOfTheSameTrack() async throws {
        let probe = ControlledLyricsRead()
        defer { Task { await probe.finishAll() } }
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            try await probe.read(url)
        }))
        let item = fixture.insertItem(named: "track.wav")
        try fixture.context.save()
        let first = Task { @MainActor in
            await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        }
        try await waitForReads(1, probe: probe)
        let second = Task { @MainActor in
            await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        }
        try await waitForReads(2, probe: probe)
        await probe.finish(1, lyrics: "Old lyrics")
        await first.value
        #expect(item.lyricsRaw == nil)

        await probe.finish(2, lyrics: "Current lyrics")
        await second.value
        #expect(item.lyricsRaw == "Current lyrics")
    }

    @Test func deletingTheItemDuringAReadDoesNotRestoreIt() async throws {
        let probe = ControlledLyricsRead()
        defer { Task { await probe.finishAll() } }
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            try await probe.read(url)
        }))
        let item = fixture.insertItem(named: "track.wav")
        try fixture.context.save()
        let task = Task { @MainActor in
            await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        }
        try await waitForReads(1, probe: probe)
        fixture.context.delete(item)
        try fixture.context.save()
        await probe.finish(1, lyrics: "Late lyrics")
        await task.value

        #expect(try fixture.context.fetchCount(FetchDescriptor<MediaItem>()) == 0)
    }

    @Test func failedReadsLeaveLyricsUnchangedAndCanBeRetried() async throws {
        let probe = LyricsReadProbe()
        let fixture = try LyricsLoadingFixture(reader: EmbeddedLyricsReader(readAsset: { url in
            await probe.record(url)
            if await probe.urls.count == 1 { throw CocoaError(.fileReadNoSuchFile) }
            return "Recovered lyrics"
        }))
        let item = fixture.insertItem(named: "track.wav", lyrics: " \n")
        try fixture.context.save()

        await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        #expect(item.lyricsRaw == " \n")
        await fixture.service.refreshMissingLyrics(for: item, in: fixture.context)
        #expect(item.lyricsRaw == "Recovered lyrics")
        #expect(await probe.urls.count == 2)
    }

    private func waitForReads(_ count: Int, probe: ControlledLyricsRead) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probe.readCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await probe.readCount >= count)
    }
}

@MainActor
private struct LyricsLoadingFixture {
    let container: ModelContainer
    let service: LibraryService
    var context: ModelContext { container.mainContext }

    init(reader: EmbeddedLyricsReader) throws {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        service = LibraryService(
            mediaDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            lyricsReader: reader
        )
    }

    func insertItem(named fileName: String, isVideo: Bool = false, lyrics: String? = nil) -> MediaItem {
        let item = MediaItem(
            title: fileName, duration: 1, isVideo: isVideo, lyricsRaw: lyrics,
            bookmarkData: Data([0xFF]), fileName: fileName
        )
        context.insert(item)
        return item
    }
}

private actor LyricsReadProbe {
    private(set) var urls: [URL] = []

    func record(_ url: URL) { urls.append(url) }
}

private actor ControlledLyricsRead {
    private(set) var readCount = 0
    private var continuations: [Int: CheckedContinuation<String?, any Error>] = [:]

    func read(_ url: URL) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            readCount += 1
            continuations[readCount] = continuation
        }
    }

    func finish(_ request: Int, lyrics: String?) {
        continuations.removeValue(forKey: request)?.resume(returning: lyrics)
    }

    func finishAll() {
        for continuation in continuations.values { continuation.resume(throwing: CancellationError()) }
        continuations.removeAll()
    }
}

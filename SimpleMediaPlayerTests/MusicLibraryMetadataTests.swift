import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

struct MusicLibraryMetadataTests {
    @Test func pathMatchPrecedesSortHintsAndUsesStandardizedPaths() {
        let snapshot = MusicLibraryMetadataSnapshot(tracks: [
            track(path: "/Music/exact.m4a", title: "Exact", sortTitle: "Different"),
            track(path: "/Music/fallback.m4a", title: "Fallback")
        ])
        expectTitle("Exact", snapshot.lookup(url: URL(fileURLWithPath: "/Music/Album/../exact.m4a"), hints: hints()))
        expectTitle("Fallback", snapshot.lookup(url: URL(fileURLWithPath: "/Imported/copy.m4a"), hints: hints()))
    }

    @Test func sortMatchRequiresArtistAlbumAndDurationAndPreservesFirstMatch() {
        let snapshot = MusicLibraryMetadataSnapshot(tracks: [
            track(title: "Wrong artist", sortArtist: "Other"),
            track(title: "Wrong album", sortAlbum: "Other"),
            track(title: "Too long", duration: 101),
            track(title: "Nonfinite", duration: .nan),
            track(title: "First", duration: 100.9),
            track(title: "Second")
        ])
        let url = URL(fileURLWithPath: "/Imported/copy.m4a")
        expectTitle("First", snapshot.lookup(url: url, hints: hints()))
        expectTitle(nil, snapshot.lookup(url: url, hints: hints(sortTitle: "")))
        expectTitle(nil, snapshot.lookup(url: url, hints: hints(duration: .infinity)))
        expectTitle("Wrong artist", snapshot.lookup(url: url, hints: hints(sortArtist: "", sortAlbum: "")))
    }

    @Test func thousandConcurrentLookupsShareOneSnapshotAndNextImportRefreshesIt() async {
        let snapshot = MusicLibraryMetadataSnapshot(tracks: [track(title: "Music title")])
        let probe = MusicSnapshotProbe(result: .loaded(snapshot))
        let provider = MusicLibraryMetadataProvider(loadSnapshot: probe.load)
        let session = provider.makeSession()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<1_000 {
                group.addTask {
                    let result = await session.lookup(
                        url: URL(fileURLWithPath: "/Imported/\(index).m4a"), hints: hints()
                    )
                    expectTitle("Music title", result)
                }
            }
        }
        #expect(probe.readCount == 1)
        expectTitle("Music title", await provider.makeSession().lookup(
            url: URL(fileURLWithPath: "/Imported/new.m4a"), hints: hints()
        ))
        #expect(probe.readCount == 2)
    }

    @Test func failedAndUnavailableSnapshotsAreNotRetriedForEachTrack() async {
        for result in [MusicLibraryMetadataSnapshotResult.failed("Permission denied"), .loaded(.init(tracks: []))] {
            let probe = MusicSnapshotProbe(result: result)
            let session = MusicLibraryMetadataProvider(loadSnapshot: probe.load).makeSession()
            for index in 0..<1_000 {
                let match = await session.lookup(url: URL(fileURLWithPath: "/Imported/\(index).m4a"), hints: hints())
                switch result {
                case .failed:
                    if case let .failed(message) = match { #expect(message == "Permission denied") } else {
                        Issue.record("Expected lookup failure")
                    }
                case .loaded: expectTitle(nil, match)
                }
            }
            #expect(probe.readCount == 1)
        }
    }

    @Test func cancelledLookupDoesNotReadMusic() async {
        let probe = MusicSnapshotProbe(result: .loaded(.init(tracks: [])))
        let session = MusicLibraryMetadataProvider(loadSnapshot: probe.load).makeSession()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await session.lookup(url: URL(fileURLWithPath: "/Imported/copy.m4a"), hints: hints())
        }
        expectTitle(nil, await task.value)
        #expect(probe.readCount == 0)
    }

    @Test func cancellationDuringSnapshotReadDiscardsResultWithoutInvalidatingOtherLookups() async throws {
        let gate = MusicSnapshotGate()
        let session = MusicLibraryMetadataProvider(loadSnapshot: gate.load).makeSession()
        let url = URL(fileURLWithPath: "/Imported/copy.m4a")
        let task = Task { await session.lookup(url: url, hints: hints()) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.hasStarted == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await gate.hasStarted
        try #require(started)
        task.cancel()
        await gate.release(.loaded(.init(tracks: [track(title: "Current title")])))
        expectTitle(nil, await task.value)
        expectTitle("Current title", await session.lookup(url: url, hints: hints()))
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func decodesMusicPropertyRecordsIncludingMissingValuesAndFileLocations(compilation: Bool) throws {
        let source = """
        using terms from application "Music"
            return {{name:"Music title", artist:"Artist", album:"Album", album artist:"Album artist", \
        composer:"Composer", genre:"Jazz", year:2026, track number:2, track count:12, \
        disc number:1, disc count:2, compilation:\(compilation), comment:"Comment", \
        sort name:"Sort title", sort artist:"Sort artist", sort album:"Sort album", duration:100.5, \
        location:POSIX file "/Music/track.m4a"}, \
        {name:missing value, genre:"  ", location:missing value}}
        end using terms from
        """
        let script = try #require(NSAppleScript(source: source))
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        try #require(errorInfo == nil)
        let snapshot = try #require(MusicLibraryMetadataProvider.snapshot(from: result))
        let match = snapshot.lookup(url: URL(fileURLWithPath: "/Music/track.m4a"), hints: hints(sortTitle: ""))
        guard case let .found(values) = match else { Issue.record("Expected location match"); return }
        #expect(values == MediaMetadataEmbeddedValues(
            title: "Music title", artist: "Artist", album: "Album", genre: "Jazz", year: "2026",
            trackNumber: "2/12", comment: "Comment", albumArtist: "Album artist", composer: "Composer",
            discNumber: "1/2", isCompilation: compilation
        ))
        expectTitle("Music title", snapshot.lookup(
            url: URL(fileURLWithPath: "/Imported/copy.m4a"),
            hints: hints(sortTitle: "Sort title", sortArtist: "Sort artist", sortAlbum: "Sort album")
        ))
        #expect(MusicLibraryMetadataProvider.snapshot(from: .list()) != nil)
        #expect(MusicLibraryMetadataProvider.snapshot(from: NSAppleEventDescriptor(string: "unexpected")) == nil)
        let malformed = NSAppleEventDescriptor.list()
        malformed.insert(NSAppleEventDescriptor(string: "not a record"), at: 1)
        #expect(MusicLibraryMetadataProvider.snapshot(from: malformed) == nil)
    }

    @Test func missingMusicPropertiesStayAbsent() throws {
        let source = """
        using terms from application "Music"
            return {{name:missing value, genre:"  ", comment:missing value, compilation:missing value, \
        year:0, track number:0, location:POSIX file "/Music/missing.m4a"}}
        end using terms from
        """
        let script = try #require(NSAppleScript(source: source))
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        try #require(errorInfo == nil)
        let snapshot = try #require(MusicLibraryMetadataProvider.snapshot(from: result))
        let match = snapshot.lookup(url: URL(fileURLWithPath: "/Music/missing.m4a"), hints: hints())
        guard case let .found(values) = match else { Issue.record("Expected location match"); return }
        #expect(values == MediaMetadataEmbeddedValues())
    }

    @Test func snapshotReaderSkipsMusicWhenItIsNotRunning() async {
        let reader = MusicLibraryScriptReader(isMusicRunning: { false })
        let result = await reader.read()
        guard case let .loaded(snapshot) = result else { Issue.record("Expected empty snapshot"); return }
        expectTitle(nil, snapshot.lookup(url: URL(fileURLWithPath: "/Music/track.m4a"), hints: hints()))
    }
    #endif
}

@MainActor
struct MusicLibraryMetadataEditingTests {
    @Test func importSupplementNeverReturnsDuringReopeningOrBulkEditing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        try writeMusicTestAudio(to: source)
        try MP4MetadataWriter.write(MediaMetadataEditDraft(
            title: "Embedded title", artist: "Artist", album: "Album", genre: "Embedded genre"
        ), to: source)
        let probe = MusicSnapshotProbe(result: .loaded(.init(tracks: [
            MusicLibraryMetadataSnapshot.Track(
                url: source, hints: hints(sortTitle: "Embedded title", duration: 0.1),
                values: MediaMetadataEmbeddedValues(
                    title: "Embedded title", genre: "Old Music genre", comment: "Old Music comment"
                )
            )
        ])))
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let service = LibraryService(
            mediaDirectoryURL: directory.appendingPathComponent("Managed"),
            musicMetadataProvider: MusicLibraryMetadataProvider(loadSnapshot: probe.load)
        )
        let context = container.mainContext
        await service.importFiles(from: [source], into: context, existingItems: [])
        #expect(service.lastImportErrors.isEmpty)
        let item = try #require(context.fetch(FetchDescriptor<MediaItem>()).first)
        #expect(item.title == "Embedded title")
        #expect(item.genre == "Old Music genre")
        #expect(probe.readCount == 1)
        var draft = try await service.editableMetadataDraft(for: item)
        draft.genre = "Edited genre"
        draft.comment = ""
        try await service.updateEmbeddedMetadata(for: item, draft: draft, in: context)
        let freshContext = ModelContext(container)
        let persisted = try #require(freshContext.fetch(FetchDescriptor<MediaItem>()).first)
        let reopened = try await service.editableMetadataDraft(for: persisted)
        #expect(reopened.genre == "Edited genre")
        #expect(reopened.comment == "")
        #expect(probe.readCount == 1)
        try await verifyBulkEditPreservesChanges(
            service: service, item: persisted, context: freshContext, draft: reopened
        )
        #expect(probe.readCount == 1)
        #expect(try MP4MetadataReader.read(from: source)?.values.genre == "Embedded genre")
    }

    private func verifyBulkEditPreservesChanges(
        service: LibraryService, item: MediaItem, context: ModelContext, draft: MediaMetadataEditDraft
    ) async throws {
        var patchDraft = draft
        patchDraft.album = "Bulk album"
        let result = await service.updateEmbeddedMetadata(
            for: [item], patch: MediaMetadataEditPatch(fields: [.album], draft: patchDraft), in: context
        )
        #expect(result.updatedCount == 1)
        #expect(result.failures.isEmpty)
        let afterBulk = try await service.editableMetadataDraft(for: item)
        #expect(afterBulk.album == "Bulk album")
        #expect(afterBulk.genre == "Edited genre")
        #expect(afterBulk.comment == "")
        let managedURL = try #require(service.resolvedURL(for: item))
        let embedded = try #require(try MP4MetadataReader.read(from: managedURL))
        #expect(embedded.values.genre == "Edited genre")
        #expect(embedded.values.comment == nil)
    }

}

private func hints(
    sortTitle: String = "Sort", sortArtist: String = "Artist", sortAlbum: String = "Album", duration: Double = 100
) -> MusicLibraryMatchHints {
    MusicLibraryMatchHints(sortTitle: sortTitle, sortArtist: sortArtist, sortAlbum: sortAlbum, duration: duration)
}

private func track(
    path: String? = nil, title: String, sortTitle: String = "Sort", sortArtist: String = "Artist",
    sortAlbum: String = "Album", duration: Double = 100
) -> MusicLibraryMetadataSnapshot.Track {
    MusicLibraryMetadataSnapshot.Track(
        url: path.map { URL(fileURLWithPath: $0) },
        hints: hints(sortTitle: sortTitle, sortArtist: sortArtist, sortAlbum: sortAlbum, duration: duration),
        values: MediaMetadataEmbeddedValues(title: title)
    )
}

private func expectTitle(_ expected: String?, _ result: MusicLibraryMetadataLookupResult) {
    switch result {
    case let .found(values): #expect(values.title == expected)
    case .notFound: #expect(expected == nil)
    case let .failed(message): Issue.record("Unexpected lookup failure: \(message)")
    }
}

private func writeMusicTestAudio(to url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
    buffer.frameLength = 4_410
    try #require(buffer.floatChannelData?[0]).update(repeating: 0.1, count: Int(buffer.frameLength))
    let encoder = try CoreAudioFileEncoder(outputURL: url, format: .aac, processingFormat: format)
    try encoder.encode(buffer: buffer)
    try encoder.finish()
}

nonisolated private final class MusicSnapshotProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let result: MusicLibraryMetadataSnapshotResult
    init(result: MusicLibraryMetadataSnapshotResult) { self.result = result }
    var readCount: Int { lock.withLock { reads } }
    func load() async -> MusicLibraryMetadataSnapshotResult {
        lock.withLock { reads += 1 }
        await Task.yield()
        return result
    }
}

private actor MusicSnapshotGate {
    private var continuation: CheckedContinuation<MusicLibraryMetadataSnapshotResult, Never>?
    var hasStarted: Bool { continuation != nil }
    func load() async -> MusicLibraryMetadataSnapshotResult {
        await withCheckedContinuation { continuation = $0 }
    }
    func release(_ result: MusicLibraryMetadataSnapshotResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

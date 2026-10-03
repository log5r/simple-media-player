import Foundation
import Observation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryListProjectionTests {
    @Test func unchangedInputsAndSelectionReuseOneComputation() async throws {
        let item = makeItem("Alpha")
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        let request = LibraryListRequest(sortField: .title)
        projection.update(items: [item], playlist: nil, request: request)
        try await waitUntil { probe.count == 1 }
        probe.finish(0)
        try await waitUntil { projection.items.count == 1 }

        for _ in 0..<50 {
            projection.update(items: [item], playlist: nil, request: request)
            projection.update(request: request)
            #expect(projection.selectedItem(id: item.id) === item)
            #expect(projection.items.count == 1)
        }
        #expect(probe.count == 1)
        #expect(probe.wasMainThread == false)

        item.lyricsRaw = "New lyrics"
        item.artworkData = Data([1])
        try await Task.sleep(for: .milliseconds(10))
        #expect(probe.count == 1)
    }

    @Test func newerSearchResultWinsWhenWorkersFinishInReverseOrder() async throws {
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [alpha, beta], playlist: nil, request: LibraryListRequest(searchText: "alpha"))
        try await waitUntil { probe.count == 1 }
        projection.update(request: LibraryListRequest(searchText: "beta"))
        try await waitUntil { probe.count == 2 }

        probe.finish(1)
        try await waitUntil { projection.items.map(\.id) == [beta.id] }
        probe.finish(0, identifiers: [alpha.id])
        try await Task.sleep(for: .milliseconds(10))
        #expect(projection.items.map(\.id) == [beta.id])
        #expect(projection.selectedItem(id: alpha.id) == nil)
    }

    @Test func metadataWillSetInvalidatesAlreadyCompletedWorkerBeforeQueuedRefresh() async throws {
        let item = makeItem("Alpha")
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [item], playlist: nil, request: LibraryListRequest(searchText: "alpha"))
        try await waitUntil { probe.count == 1 }

        // Both operations happen in one MainActor turn: the old completion may already be
        // queued when Observation's willSet callback schedules the replacement snapshot.
        probe.finish(0, identifiers: [item.id])
        item.title = "Beta"
        try await waitUntil { probe.count == 2 }
        #expect(projection.items.isEmpty)
        #expect(probe.snapshot(at: 1).items.first?.title == "Beta")
        probe.finish(1)
        try await Task.sleep(for: .milliseconds(10))
        #expect(projection.items.isEmpty)
    }

    @Test(arguments: LibraryListObservedField.allCases)
    private func everySearchAndSortFieldInvalidatesTheObservedSource(_ field: LibraryListObservedField) async throws {
        let item = makeItem("Alpha")
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [item], playlist: nil, request: LibraryListRequest())
        try await waitUntil { probe.count == 1 }
        field.change(item)
        try await waitUntil { probe.count == 2 }
        let before = probe.snapshot(at: 0).items.first.map(field.value)
        let after = probe.snapshot(at: 1).items.first.map(field.value)
        #expect(before != after)
    }

    @Test func requestChangesReuseFrozenMetadataUntilTheModelChanges() async throws {
        let item = makeItem("Alpha")
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [item], playlist: nil, request: LibraryListRequest())
        try await waitUntil { probe.count == 1 }
        projection.update(request: LibraryListRequest(searchText: "alpha", sortField: .title))
        try await waitUntil { probe.count == 2 }
        #expect(probe.snapshot(at: 1).items.first?.title == "Alpha")
        item.title = "Beta"
        try await waitUntil { probe.count == 3 }
        #expect(probe.snapshot(at: 0).items.first?.title == "Alpha")
        #expect(probe.snapshot(at: 2).items.first?.title == "Beta")
    }

    @Test(arguments: LibraryListPlaylistChange.allCases)
    private func playlistEntriesOrderAndRelationshipChangesAreObserved(
        _ change: LibraryListPlaylistChange
    ) async throws {
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let playlist = Playlist(name: "Playlist")
        let first = PlaylistEntry(sortIndex: 0, playlist: playlist, item: alpha)
        let second = PlaylistEntry(sortIndex: 1, playlist: playlist, item: beta)
        playlist.entries = [second, first]
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(
            items: [alpha, beta], playlist: playlist,
            request: LibraryListRequest(section: .allVideos, sortField: .title, sortDirection: .descending)
        )
        try await waitUntil { probe.count == 1 }
        probe.finish(0)
        try await waitUntil { projection.items.map(\.id) == [alpha.id, beta.id] }
        switch change {
        case .entries: playlist.entries = [second]
        case .order: first.sortIndex = 2
        case .relationship: first.item = nil
        }
        try await waitUntil { probe.count == 2 }
        if change != .order {
            #expect(projection.items.map(\.id) == [beta.id])
            #expect(projection.selectedItem(id: alpha.id) == nil)
        }
        probe.finish(1)
        let expected = change == .order ? [beta.id, alpha.id] : [beta.id]
        try await waitUntil { projection.items.map(\.id) == expected }
    }

    @Test func deletedSourceIsPrunedBeforeReplacementComputationFinishes() async throws {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let alphaID = alpha.id
        container.mainContext.insert(alpha)
        container.mainContext.insert(beta)
        try container.mainContext.save()
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        let request = LibraryListRequest(sortField: .title)
        projection.update(items: [alpha, beta], playlist: nil, request: request)
        try await waitUntil { probe.count == 1 }
        probe.finish(0)
        try await waitUntil { projection.items.count == 2 }

        container.mainContext.delete(alpha)
        try container.mainContext.save()
        projection.update(items: [beta], playlist: nil, request: request)
        #expect(projection.items.map(\.id) == [beta.id])
        #expect(projection.selectedItem(id: alphaID) == nil)
        try await waitUntil { probe.count == 2 }
        probe.finish(1)
        try await waitUntil { projection.items.map(\.id) == [beta.id] }
    }

    @Test func cancellingAndReappearingWithIdenticalInputsStartsANewWorker() async throws {
        let item = makeItem("Alpha")
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        let request = LibraryListRequest()
        projection.update(items: [item], playlist: nil, request: request)
        try await waitUntil { probe.count == 1 }
        projection.cancel()
        probe.finish(0, identifiers: [item.id])
        try await Task.sleep(for: .milliseconds(10))
        #expect(projection.items.isEmpty)

        projection.update(items: [item], playlist: nil, request: request)
        try await waitUntil { probe.count == 2 }
        probe.finish(1)
        try await waitUntil { projection.items.map(\.id) == [item.id] }
        #expect(projection.selectedItem(id: item.id) === item)
    }

    @Test func savedDeletionCannotBePublishedBeforeTheQueryReceivesItsNewArray() async throws {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let alphaID = alpha.id
        let betaID = beta.id
        container.mainContext.insert(alpha)
        container.mainContext.insert(beta)
        try container.mainContext.save()
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [alpha, beta], playlist: nil, request: LibraryListRequest())
        try await waitUntil { probe.count == 1 }

        container.mainContext.delete(alpha)
        try container.mainContext.save()
        // SwiftData resets isDeleted and clears the context after save, without sending a
        // metadata Observation callback. Do not supply a replacement @Query array yet.
        #expect(alpha.isDeleted == false)
        #expect(alpha.modelContext == nil)
        probe.finish(0, identifiers: [alphaID, betaID])
        try await waitUntil { projection.items.map(\.id) == [betaID] }
        #expect(projection.selectedItem(id: alphaID) == nil)
    }

    @Test func destinationChangeClearsPreviousPublishedQueueImmediately() async throws {
        let audio = makeItem("Audio")
        let video = makeItem("Video", isVideo: true)
        let projection = LibraryListProjection()
        defer { projection.cancel() }
        projection.update(items: [audio, video], playlist: nil, request: LibraryListRequest(section: .allSongs))
        try await waitUntil { projection.items.map(\.id) == [audio.id] }
        projection.update(request: LibraryListRequest(section: .allVideos))
        #expect(projection.items.isEmpty)
        #expect(projection.selectedItem(id: audio.id) == nil)
        try await waitUntil { projection.items.map(\.id) == [video.id] }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while condition() == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition(), "The list computation did not reach the expected state")
    }

    private func makeItem(_ title: String, isVideo: Bool = false) -> MediaItem {
        MediaItem(title: title, duration: 120, isVideo: isVideo, bookmarkData: Data(), fileName: "\(title).mp3")
    }
}

nonisolated private enum LibraryListPlaylistChange: CaseIterable {
    case entries, order, relationship
}

nonisolated private enum LibraryListObservedField: CaseIterable {
    case title, artist, album, genre, albumArtist, composer, year, trackNumber, discNumber
    case duration, isVideo, addedAt, fileName

    @MainActor func change(_ item: MediaItem) {
        switch self {
        case .duration: item.duration = 200
        case .isVideo: item.isVideo = true
        case .addedAt: item.addedAt = .distantPast
        case .fileName: item.fileName = "Changed.wav"
        default: changeText(item)
        }
    }

    @MainActor private func changeText(_ item: MediaItem) {
        switch self {
        case .title: item.title = "Changed"
        case .artist: item.artist = "Changed"
        case .album: item.album = "Changed"
        case .genre: item.genre = "Changed"
        case .albumArtist: item.albumArtist = "Changed"
        case .composer: item.composer = "Changed"
        case .year: item.year = "2000"
        case .trackNumber: item.trackNumber = "2"
        case .discNumber: item.discNumber = "2"
        default: break
        }
    }

    func value(_ item: LibraryListItemSnapshot) -> String {
        switch self {
        case .title: item.title
        case .artist: item.artist
        case .album: item.album
        case .genre: item.genre ?? ""
        case .albumArtist: item.albumArtist ?? ""
        case .composer: item.composer ?? ""
        case .year: item.year ?? ""
        case .trackNumber: item.trackNumber ?? ""
        case .discNumber: item.discNumber ?? ""
        default: nonTextValue(item)
        }
    }

    private func nonTextValue(_ item: LibraryListItemSnapshot) -> String {
        switch self {
        case .duration: String(item.duration)
        case .isVideo: String(item.isVideo)
        case .addedAt: String(item.addedAt.timeIntervalSince1970)
        case .fileName: item.fileName
        default: ""
        }
    }
}

nonisolated final class LibraryListComputationProbe: @unchecked Sendable {
    private struct Call {
        let snapshot: LibraryListSnapshot
        var continuation: CheckedContinuation<[UUID], Never>?
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var mainThread = false

    var count: Int { lock.withLock { calls.count } }
    var wasMainThread: Bool { lock.withLock { mainThread } }

    func compute(_ snapshot: LibraryListSnapshot) async -> [UUID] {
        await withCheckedContinuation { continuation in
            lock.withLock {
                mainThread = mainThread || Thread.isMainThread
                calls.append(Call(snapshot: snapshot, continuation: continuation))
            }
        }
    }

    func snapshot(at index: Int) -> LibraryListSnapshot { lock.withLock { calls[index].snapshot } }

    func finish(_ index: Int, identifiers: [UUID]? = nil) {
        let call = lock.withLock {
            let call = calls[index]
            calls[index].continuation = nil
            return call
        }
        call.continuation?.resume(returning: identifiers ?? call.snapshot.identifiers())
    }

    func finishAll() {
        let pending = lock.withLock {
            let pending = calls
            for index in calls.indices { calls[index].continuation = nil }
            return pending
        }
        for call in pending { call.continuation?.resume(returning: []) }
    }
}

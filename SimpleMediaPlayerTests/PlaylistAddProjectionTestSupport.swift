import Foundation
import os
import SwiftData
import Testing
@testable import SimpleMediaPlayer

nonisolated final class PlaylistAddComputationProbe: @unchecked Sendable {
    private struct Call {
        let snapshot: PlaylistAddCandidateSnapshot
        let query: String
        let isMainThread: Bool
        var continuation: CheckedContinuation<[UUID], Never>?
    }
    private struct State {
        var calls: [Call] = []
        var closed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var count: Int { state.withLock { $0.calls.count } }
    var wasMainThread: Bool { state.withLock { $0.calls.contains { $0.isMainThread } } }

    func compute(_ snapshot: PlaylistAddCandidateSnapshot, _ query: String) async -> [UUID] {
        await withCheckedContinuation { continuation in
            let closed = state.withLock { state in
                guard state.closed == false else { return true }
                state.calls.append(Call(
                    snapshot: snapshot, query: query, isMainThread: Thread.isMainThread, continuation: continuation
                ))
                return false
            }
            if closed { continuation.resume(returning: []) }
        }
    }

    func snapshot(at index: Int) -> PlaylistAddCandidateSnapshot { state.withLock { $0.calls[index].snapshot } }
    func query(at index: Int) -> String { state.withLock { $0.calls[index].query } }

    func finish(_ index: Int, identifiers: [UUID]? = nil) {
        let call = state.withLock { state -> Call in
            let value = state.calls[index]
            state.calls[index].continuation = nil
            return value
        }
        call.continuation?.resume(returning: identifiers ?? call.snapshot.identifiers(searchText: call.query))
    }

    func finishAll() {
        let values = state.withLock { state -> [Call] in
            state.closed = true
            let result = state.calls
            for index in state.calls.indices { state.calls[index].continuation = nil }
            return result
        }
        for call in values { call.continuation?.resume(returning: []) }
    }
}

@MainActor
struct PlaylistAddDeletionFixture {
    let container: ModelContainer
    let alpha: MediaItem
    let beta: MediaItem
    let alphaID: UUID
    let betaID: UUID
    let playlist: Playlist
    let entry: PlaylistEntry
    var context: ModelContext { container.mainContext }
    var items: [MediaItem] { [alpha, beta] }

    init() throws {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
        alpha = MediaItem(title: "Alpha", duration: 1, isVideo: false, bookmarkData: Data(), fileName: "alpha.mp3")
        beta = MediaItem(title: "Beta", duration: 1, isVideo: false, bookmarkData: Data(), fileName: "beta.mp3")
        alphaID = alpha.id
        betaID = beta.id
        playlist = Playlist(name: "Playlist")
        entry = PlaylistEntry(sortIndex: 0, playlist: playlist, item: alpha)
        playlist.entries = [entry]
        context.insert(playlist)
        context.insert(alpha)
        context.insert(beta)
        try context.save()
    }
}

nonisolated enum PlaylistAddObservedField: CaseIterable {
    case identifier, title, artist, album, genre

    @MainActor func change(_ item: MediaItem) {
        switch self {
        case .identifier: item.id = UUID()
        case .title: item.title = "Changed title"
        case .artist: item.artist = "Changed artist"
        case .album: item.album = "Changed album"
        case .genre: item.genre = "Changed genre"
        }
    }
}

nonisolated enum PlaylistAddEntryChange: CaseIterable {
    case insert, remove, relationship
}

nonisolated enum PlaylistAddDeletedModel: CaseIterable {
    case item, entry, playlist
}

nonisolated final class PlaylistAddCancellationCounter: @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var reads: Int { count.withLock { $0 } }
    func title() -> String {
        let reads = count.withLock { value in
            value += 1
            return value
        }
        if reads == 50 { withUnsafeCurrentTask { $0?.cancel() } }
        return "No match"
    }
}

nonisolated struct PlaylistAddCancellationItem: PlaylistAddItemValues, Sendable {
    let id = UUID()
    let counter: PlaylistAddCancellationCounter
    var title: String { counter.title() }
    let artist = ""
    let album = ""
    let genre: String? = nil
}

import Foundation
@testable import SimpleMediaPlayer

nonisolated enum LibraryListPlaylistChange: CaseIterable {
    case entries, order, relationship
}

nonisolated enum LibraryListObservedField: CaseIterable {
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
    private var isClosed = false

    var count: Int { lock.withLock { calls.count } }
    var wasMainThread: Bool { lock.withLock { mainThread } }

    func compute(_ snapshot: LibraryListSnapshot) async -> [UUID] {
        await withCheckedContinuation { continuation in
            let closed = lock.withLock {
                guard !isClosed else { return true }
                mainThread = mainThread || Thread.isMainThread
                calls.append(Call(snapshot: snapshot, continuation: continuation))
                return false
            }
            if closed { continuation.resume(returning: []) }
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
            isClosed = true
            let pending = calls
            for index in calls.indices { calls[index].continuation = nil }
            return pending
        }
        for call in pending { call.continuation?.resume(returning: []) }
    }
}

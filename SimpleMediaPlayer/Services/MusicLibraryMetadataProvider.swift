import Foundation
#if os(macOS)
import AppKit
#endif

nonisolated struct MusicLibraryMatchHints: Equatable, Sendable {
    var sortTitle: String?
    var sortArtist: String?
    var sortAlbum: String?
    var duration: TimeInterval
}

nonisolated enum MusicLibraryMetadataLookupResult: Sendable {
    case found(MediaMetadataEmbeddedValues)
    case notFound
    case failed(String)
}

nonisolated struct MusicLibraryMetadataSnapshot: Sendable {
    struct Track: Sendable {
        var url: URL?
        var hints: MusicLibraryMatchHints
        var values: MediaMetadataEmbeddedValues
    }

    private let tracksByPath: [String: Track]
    private let tracksBySortTitle: [String: [Track]]

    init(tracks: [Track]) {
        var paths: [String: Track] = [:]
        var titles: [String: [Track]] = [:]
        for track in tracks {
            if let path = track.url?.standardizedFileURL.path, paths[path] == nil { paths[path] = track }
            if let title = track.hints.sortTitle, title.isEmpty == false { titles[title, default: []].append(track) }
        }
        tracksByPath = paths
        tracksBySortTitle = titles
    }

    func lookup(url: URL, hints: MusicLibraryMatchHints) -> MusicLibraryMetadataLookupResult {
        if let track = tracksByPath[url.standardizedFileURL.path] { return .found(track.values) }
        guard let title = hints.sortTitle, title.isEmpty == false, hints.duration.isFinite else { return .notFound }
        let track = tracksBySortTitle[title]?.first {
            (hints.sortArtist?.isEmpty != false || $0.hints.sortArtist == hints.sortArtist)
                && (hints.sortAlbum?.isEmpty != false || $0.hints.sortAlbum == hints.sortAlbum)
                && $0.hints.duration.isFinite && abs($0.hints.duration - max(0, hints.duration)) < 1
        }
        return track.map { .found($0.values) } ?? .notFound
    }
}

nonisolated enum MusicLibraryMetadataSnapshotResult: Sendable {
    case loaded(MusicLibraryMetadataSnapshot)
    case failed(String)
}

nonisolated struct MusicLibraryMetadataProvider: Sendable {
    var loadSnapshot: @Sendable () async -> MusicLibraryMetadataSnapshotResult = {
        #if os(macOS)
        return await MusicLibraryScriptReader.shared.read()
        #else
        return .loaded(MusicLibraryMetadataSnapshot(tracks: []))
        #endif
    }

    func makeSession() -> MusicLibraryMetadataSession {
        MusicLibraryMetadataSession(loadSnapshot: loadSnapshot)
    }
}

// One lazy snapshot per import, including failed/unavailable reads. Never cache it across imports.
actor MusicLibraryMetadataSession {
    private let loadSnapshot: @Sendable () async -> MusicLibraryMetadataSnapshotResult
    private var snapshotTask: Task<MusicLibraryMetadataSnapshotResult, Never>?

    init(loadSnapshot: @escaping @Sendable () async -> MusicLibraryMetadataSnapshotResult) {
        self.loadSnapshot = loadSnapshot
    }

    func lookup(url: URL, hints: MusicLibraryMatchHints) async -> MusicLibraryMetadataLookupResult {
        guard Task.isCancelled == false else { return .notFound }
        if snapshotTask == nil { snapshotTask = Task { await loadSnapshot() } }
        guard let result = await snapshotTask?.value, Task.isCancelled == false else { return .notFound }
        switch result {
        case let .loaded(snapshot): return snapshot.lookup(url: url, hints: hints)
        case let .failed(message): return .failed(message)
        }
    }
}

#if os(macOS)
// Script creation, execution and descriptor decoding share a serial worker, outside MainActor
// and the cooperative executor. Only immutable Swift values leave this queue.
nonisolated final class MusicLibraryScriptReader: @unchecked Sendable {
    static let shared = MusicLibraryScriptReader()
    private let queue = DispatchQueue(label: "SimpleMediaPlayer.MusicLibraryMetadata", qos: .utility)
    private var script: NSAppleScript?
    private let isMusicRunning: @Sendable () -> Bool

    init(isMusicRunning: @escaping @Sendable () -> Bool = {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            .contains(where: { $0.isTerminated == false })
    }) {
        self.isMusicRunning = isMusicRunning
    }

    func read() async -> MusicLibraryMetadataSnapshotResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readSynchronously()) }
        }
    }

    private func readSynchronously() -> MusicLibraryMetadataSnapshotResult {
        guard isMusicRunning() else {
            return .loaded(MusicLibraryMetadataSnapshot(tracks: []))
        }
        if script == nil { script = NSAppleScript(source: MusicLibraryMetadataProvider.appleScriptSource) }
        guard let script else { return .failed(L10n.string("Could not prepare Music library access.")) }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return .failed((errorInfo[NSAppleScript.errorMessage] as? String)
                ?? L10n.string("Music library access failed."))
        }
        guard let snapshot = MusicLibraryMetadataProvider.snapshot(from: result) else {
            return .failed(L10n.string("Music library access failed."))
        }
        return .loaded(snapshot)
    }
}

extension MusicLibraryMetadataProvider {
    // `properties of every file track` is one bulk request. Its result contains records,
    // not track references, so descriptor decoding performs no further Music requests.
    // Keep AppleScript's standard response timeout for potentially slow whole-library reads.
    nonisolated static var appleScriptSource: String {
        """
        if application "Music" is not running then return {}
        tell application "Music"
            return properties of every file track of library playlist 1
        end tell
        """
    }

    nonisolated static func snapshot(from result: NSAppleEventDescriptor) -> MusicLibraryMetadataSnapshot? {
        guard result.descriptorType == typeAEList else { return nil }
        var tracks: [MusicLibraryMetadataSnapshot.Track] = []
        for index in 0..<result.numberOfItems {
            guard let record = result.atIndex(index + 1), record.descriptorType == typeAERecord else { return nil }
            var values = MediaMetadataEmbeddedValues()
            values.title = text(record, "pnam")
            values.artist = text(record, "pArt")
            values.album = text(record, "pAlb")
            values.albumArtist = text(record, "pAlA")
            values.composer = text(record, "pCmp")
            values.genre = text(record, "pGen")
            let year = field(record, "pYr ")?.int32Value ?? 0
            values.year = year > 0 ? String(year) : nil
            values.trackNumber = numberPair(record, current: "pTrN", total: "pTrC")
            values.discNumber = numberPair(record, current: "pDsN", total: "pDsC")
            let compilation = field(record, "pAnt")
            if let compilation, [typeBoolean, typeTrue, typeFalse].contains(compilation.descriptorType) {
                values.isCompilation = compilation.booleanValue
            }
            values.comment = text(record, "pCmt")
            tracks.append(MusicLibraryMetadataSnapshot.Track(
                url: field(record, "pLoc")?.coerce(toDescriptorType: typeFileURL)?.fileURLValue,
                hints: MusicLibraryMatchHints(
                    sortTitle: text(record, "pSNm"), sortArtist: text(record, "pSAr"),
                    sortAlbum: text(record, "pSAl"),
                    duration: field(record, "pDur")?.doubleValue ?? .nan
                ),
                values: values
            ))
        }
        return MusicLibraryMetadataSnapshot(tracks: tracks)
    }

    nonisolated private static func field(_ record: NSAppleEventDescriptor, _ code: String) -> NSAppleEventDescriptor? {
        record.forKeyword(code.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }

    nonisolated private static func text(_ record: NSAppleEventDescriptor, _ code: String) -> String? {
        let value = field(record, code)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    nonisolated private static func numberPair(
        _ record: NSAppleEventDescriptor, current: String, total: String
    ) -> String? {
        let current = field(record, current)?.int32Value ?? 0
        let total = field(record, total)?.int32Value ?? 0
        guard current > 0 else { return nil }
        return total > 0 ? "\(current)/\(total)" : "\(current)"
    }
}
#endif

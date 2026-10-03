import AVFoundation
import Foundation

// All mutable state is guarded by condition; decoding never holds it.
nonisolated final class ExtendedAudioCache: @unchecked Sendable {
    private final class Request: @unchecked Sendable {
        var users = 0
        var decoding = false
        var invalidated = false
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let modified: Date
    }

    private let condition = NSCondition()
    private var requests: [URL: Request] = [:]
    private let maximumBytes: Int64

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
    }

    func readableURL(
        at destination: URL,
        create: (URL, @escaping @Sendable () -> Bool) throws -> Void,
        isSourceCurrent: () throws -> Bool
    ) throws -> URL {
        let request = beginRequest(at: destination)
        defer { endRequest(request, at: destination) }
        guard try claimDecode(request, at: destination, isSourceCurrent: isSourceCurrent) else {
            return destination
        }
        defer { finishDecode(request) }

        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial.caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try create(temporary, { self.isInvalidated(request) || Task<Never, Never>.isCancelled })
        try Task.checkCancellation()

        condition.lock()
        defer { condition.unlock() }
        guard !request.invalidated, try isSourceCurrent() else { throw CancellationError() }
        guard let file = try? AVAudioFile(forReading: temporary), file.length > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        prune(in: directory, preserving: destination)
        return destination
    }

    func invalidate(at destination: URL) {
        condition.lock()
        defer { condition.unlock() }
        requests.removeValue(forKey: destination)?.invalidated = true
        condition.broadcast()
    }

    func remove(at destination: URL) {
        condition.lock()
        defer { condition.unlock() }
        requests.removeValue(forKey: destination)?.invalidated = true
        try? FileManager.default.removeItem(at: destination)
        condition.broadcast()
    }

    private func beginRequest(at destination: URL) -> Request {
        condition.lock()
        defer { condition.unlock() }
        let request = requests[destination] ?? Request()
        requests[destination] = request
        request.users += 1
        return request
    }

    private func endRequest(_ request: Request, at destination: URL) {
        condition.lock()
        defer { condition.unlock() }
        request.users -= 1
        if request.users == 0, requests[destination] === request {
            requests.removeValue(forKey: destination)
        }
    }

    private func claimDecode(
        _ request: Request, at destination: URL, isSourceCurrent: () throws -> Bool
    ) throws -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while true {
            try Task.checkCancellation()
            guard !request.invalidated else { throw CancellationError() }
            if !request.decoding {
                if let file = try? AVAudioFile(forReading: destination), file.length > 0 {
                    guard try isSourceCurrent() else { throw CancellationError() }
                    try Task.checkCancellation()
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date()], ofItemAtPath: destination.path
                    )
                    return false
                }
                try? FileManager.default.removeItem(at: destination)
                request.decoding = true
                return true
            }
            // Poll cancellation only for the same key; other tracks never wait here.
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private func isInvalidated(_ request: Request) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return request.invalidated
    }

    private func finishDecode(_ request: Request) {
        condition.lock()
        defer { condition.unlock() }
        request.decoding = false
        condition.broadcast()
    }

    private func prune(in directory: URL, preserving keptURL: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }
        let entries = urls.compactMap { url -> Entry? in
            guard url.pathExtension == "caf", !url.lastPathComponent.hasPrefix("."),
                  let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize, let date = values.contentModificationDate else { return nil }
            return Entry(url: url, size: Int64(size), modified: date)
        }.sorted { $0.modified < $1.modified }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        for entry in entries where total > maximumBytes && entry.url != keptURL {
            do {
                try FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            } catch { continue }
        }
    }
}

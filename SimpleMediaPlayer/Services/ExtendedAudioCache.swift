import AVFoundation
import Foundation

// State uses condition; filesystem operations use fileLock and never hold condition.
// Workers take fileLock before briefly inspecting state; decoding holds neither lock.
nonisolated final class ExtendedAudioCache: @unchecked Sendable {
    final class ReadableFile: @unchecked Sendable {
        let url: URL
        private let lock = NSLock()
        private var onRelease: (@Sendable () -> Void)?

        init(url: URL, onRelease: (@Sendable () -> Void)? = nil) {
            self.url = url
            self.onRelease = onRelease
        }

        // Keep the lease through the last URL consumer, including lazy asset reads.
        func release() {
            let action = lock.withLock {
                let action = onRelease
                onRelease = nil
                return action
            }
            action?()
        }

        deinit { release() }
    }

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
    private let fileLock = NSLock()
    private var requests: [URL: Request] = [:]
    private var activeTemporaryURLs: Set<URL> = []
    private var pendingRemovals: [URL: UUID] = [:]
    private let maximumBytes: Int64
    private let maintenanceQueue: DispatchQueue

    init(
        maximumBytes: Int64,
        maintenanceQueue: DispatchQueue = DispatchQueue(label: "ExtendedAudioCache.maintenance", qos: .utility)
    ) {
        self.maximumBytes = maximumBytes
        self.maintenanceQueue = maintenanceQueue
    }

    func acquireReadableFile(
        at destination: URL,
        create: (URL, @escaping @Sendable () -> Bool) throws -> Void,
        isSourceCurrent: () throws -> Bool
    ) throws -> ReadableFile {
        let request = beginRequest(at: destination)
        var acquired = false
        defer { if !acquired { scheduleEndRequest(request, at: destination) } }
        guard try claimDecode(request, at: destination, isSourceCurrent: isSourceCurrent) else {
            acquired = true
            return lease(request, at: destination)
        }
        defer { finishDecode(request) }

        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial.caf")
        fileLock.withLock { _ = condition.withLock { activeTemporaryURLs.insert(temporary) } }
        defer { removeTemporary(at: temporary) }
        try create(temporary, { self.isInvalidated(request) || Task<Never, Never>.isCancelled })
        try Task.checkCancellation()

        fileLock.lock()
        defer { fileLock.unlock() }
        try checkCurrent(request)
        guard try isSourceCurrent() else { throw CancellationError() }
        guard let file = try? AVAudioFile(forReading: temporary), file.length > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try checkCurrent(request)
        try FileManager.default.moveItem(at: temporary, to: destination)
        do {
            try checkCurrent(request)
            guard try isSourceCurrent() else { throw CancellationError() }
            prune(in: directory)
            try checkCurrent(request)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        acquired = true
        return lease(request, at: destination)
    }

    private func lease(_ request: Request, at destination: URL) -> ReadableFile {
        ReadableFile(url: destination) { self.scheduleEndRequest(request, at: destination) }
    }

    func invalidate(at destination: URL) {
        condition.lock()
        defer { condition.unlock() }
        requests.removeValue(forKey: destination)?.invalidated = true
        condition.broadcast()
    }

    func remove(at destination: URL) {
        removeIfPending(at: destination, removal: markRemoval(at: destination))
    }

    func removeInBackground(at destination: URL) {
        let removal = markRemoval(at: destination)
        maintenanceQueue.async { self.removeIfPending(at: destination, removal: removal) }
    }

    private func markRemoval(at destination: URL) -> UUID {
        condition.lock()
        defer { condition.unlock() }
        requests.removeValue(forKey: destination)?.invalidated = true
        let removal = UUID()
        pendingRemovals[destination] = removal
        condition.broadcast()
        return removal
    }

    private func removeIfPending(at destination: URL, removal: UUID) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let isPending = condition.withLock {
            guard pendingRemovals[destination] == removal else { return false }
            pendingRemovals.removeValue(forKey: destination)
            return true
        }
        if isPending { try? FileManager.default.removeItem(at: destination) }
    }

    private func beginRequest(at destination: URL) -> Request {
        fileLock.lock()
        defer { fileLock.unlock() }
        condition.lock()
        let needsRemoval = pendingRemovals.removeValue(forKey: destination) != nil
        let request = requests[destination] ?? Request()
        requests[destination] = request
        request.users += 1
        condition.unlock()
        // A new generation must not read the entry awaiting deferred deletion.
        if needsRemoval { try? FileManager.default.removeItem(at: destination) }
        removeAbandonedTemporaryFiles(in: destination.deletingLastPathComponent())
        return request
    }

    private func scheduleEndRequest(_ request: Request, at destination: URL) {
        // Callers may release on MainActor, so even waiting for the cache lock stays off it.
        maintenanceQueue.async { self.endRequest(request, at: destination) }
    }

    private func endRequest(_ request: Request, at destination: URL) {
        condition.lock()
        request.users -= 1
        if request.users == 0, requests[destination] === request {
            requests.removeValue(forKey: destination)
        }
        let noUsersRemain = request.users == 0
        condition.unlock()
        if noUsersRemain { fileLock.withLock { prune(in: destination.deletingLastPathComponent()) } }
    }

    private func removeTemporary(at temporary: URL) {
        fileLock.lock()
        defer { fileLock.unlock() }
        try? FileManager.default.removeItem(at: temporary)
        _ = condition.withLock { activeTemporaryURLs.remove(temporary) }
    }

    private func removeAbandonedTemporaryFiles(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for listedURL in urls where listedURL.lastPathComponent.hasPrefix(".")
            && listedURL.lastPathComponent.hasSuffix(".partial.caf") {
            let url = directory.appendingPathComponent(listedURL.lastPathComponent)
            guard !condition.withLock({ activeTemporaryURLs.contains(url) }) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func claimDecode(
        _ request: Request, at destination: URL, isSourceCurrent: () throws -> Bool
    ) throws -> Bool {
        try reserveDecode(request)
        var needsDecode = false
        defer { if !needsDecode { finishDecode(request) } }
        fileLock.lock()
        defer { fileLock.unlock() }
        try checkCurrent(request)
        if let file = try? AVAudioFile(forReading: destination), file.length > 0 {
            guard try isSourceCurrent() else { throw CancellationError() }
            try checkCurrent(request)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: destination.path
            )
            try checkCurrent(request)
            return false
        }
        try? FileManager.default.removeItem(at: destination)
        try checkCurrent(request)
        needsDecode = true
        return true
    }

    private func reserveDecode(_ request: Request) throws {
        condition.lock()
        defer { condition.unlock() }
        while true {
            try Task.checkCancellation()
            guard !request.invalidated else { throw CancellationError() }
            if !request.decoding {
                request.decoding = true
                return
            }
            // Poll cancellation only for the same key; other tracks never wait here.
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private func checkCurrent(_ request: Request) throws {
        try Task.checkCancellation()
        if isInvalidated(request) { throw CancellationError() }
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

    private func prune(in directory: URL) {
        removeAbandonedTemporaryFiles(in: directory)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }
        let entries = urls.compactMap { listedURL -> Entry? in
            // Foundation may enumerate /var through /private/var; retain the caller's directory spelling.
            let url = directory.appendingPathComponent(listedURL.lastPathComponent)
            guard url.pathExtension == "caf", !url.lastPathComponent.hasPrefix("."),
                  let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize, let date = values.contentModificationDate else { return nil }
            return Entry(url: url, size: Int64(size), modified: date)
        }.sorted { $0.modified < $1.modified }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        for entry in entries where total > maximumBytes {
            guard condition.withLock({ (requests[entry.url]?.users ?? 0) == 0 }) else { continue }
            do {
                try FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            } catch { continue }
        }
    }
}

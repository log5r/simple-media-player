import Foundation

nonisolated enum MediaFileRewriter {
    static let copyBufferSize = 1_048_576

    /// `write` may change metadata only; the music analysis cache follows the rewritten file.
    static func rewrite(
        at url: URL,
        analysisCacheDirectory: URL? = MusicAnalysisCache.defaultDirectory,
        _ write: (FileHandle, FileHandle, UInt64) throws -> Void
    ) throws {
        let analysisCacheEntry = MusicAnalysisCache.entryURL(for: url, in: analysisCacheDirectory)
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let fileSize = try source.seekToEnd()
        let manager = FileManager.default
        // A sibling directory keeps the replacement on the source volume.
        let temporaryDirectory = url.deletingLastPathComponent()
            .appendingPathComponent(".metadata-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var removeTemporaryDirectory = true
        defer {
            if removeTemporaryDirectory { try? manager.removeItem(at: temporaryDirectory) }
        }

        let temporaryURL = temporaryDirectory.appendingPathComponent("replacement")
        guard manager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer { try? output.close() }

        try write(source, output, fileSize)
        try Task.checkCancellation()
        try output.synchronize()
        try output.close()
        try source.close()
        do {
            _ = try manager.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            // Foundation can leave the original at a recovery URL after replacement fails.
            if let recoveryURL = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL,
               recoveryURL.path.hasPrefix(temporaryDirectory.path + "/") {
                removeTemporaryDirectory = false
            }
            throw error
        }
        MusicAnalysisCache.carryOver(analysisCacheEntry, to: url, in: analysisCacheDirectory)
    }

    static func read(from handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    static func copy(from source: FileHandle, range: Range<UInt64>, to output: FileHandle) throws {
        try source.seek(toOffset: range.lowerBound)
        var remaining = range.upperBound - range.lowerBound
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(UInt64(copyBufferSize), remaining))
            // FileHandle may return autoreleased NSData; release it after each chunk.
            try autoreleasepool {
                guard let data = try source.read(upToCount: count), data.count == count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try output.write(contentsOf: data)
            }
            remaining -= UInt64(count)
        }
    }
}

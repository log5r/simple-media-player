import Foundation

nonisolated enum MediaFileRewriter {
    static let copyBufferSize = 1_048_576

    /// Replaces the `originalLength` bytes at `offset` with `data`, which must be the same length unless the range
    /// ends at the end of the file; the file then ends at `newFileLength`, the end of `data`.
    struct InPlaceEdit {
        let offset: UInt64
        let originalLength: UInt64
        let data: Data
        var newFileLength: UInt64?
    }

    /// Test hook: performs the write of an in-place edit, so tests can fail after a partial write.
    @TaskLocal static var inPlaceWrite: @Sendable (FileHandle, Data) throws -> Void = { handle, data in
        try handle.write(contentsOf: data)
    }
    /// Test hook: false makes `update` always rewrite, so tests can compare both outputs.
    @TaskLocal static var allowsInPlaceEdits = true

    /// Overwrites only the range `plan` returns, or rewrites the whole file through `rewrite(at:_:)` when it returns
    /// nil. Cancellation is honored until the first write; after a failed write the original bytes are restored.
    /// Unlike the replacement, an interruption during the write (a crash or power loss) can leave a partial edit.
    static func update(
        at url: URL,
        analysisCacheDirectory: URL? = MusicAnalysisCache.defaultDirectory,
        plan: (FileHandle, UInt64) throws -> InPlaceEdit?,
        rewrite write: (FileHandle, FileHandle, UInt64) throws -> Void
    ) throws {
        guard allowsInPlaceEdits else {
            return try rewrite(at: url, analysisCacheDirectory: analysisCacheDirectory, write)
        }
        let analysisCacheEntry = MusicAnalysisCache.entryURL(for: url, in: analysisCacheDirectory)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard let edit = try plan(handle, fileSize), isValid(edit, fileSize: fileSize) else {
            try handle.close()
            return try rewrite(at: url, analysisCacheDirectory: analysisCacheDirectory, write)
        }
        let original = try read(from: handle, at: edit.offset, count: Int(edit.originalLength))
        try Task.checkCancellation()
        // Once writing starts, finish or restore instead of stopping for cancellation.
        do {
            try handle.seek(toOffset: edit.offset)
            try inPlaceWrite(handle, edit.data)
            if let newFileLength = edit.newFileLength { try handle.truncate(atOffset: newFileLength) }
            try handle.synchronize()
        } catch {
            try? handle.truncate(atOffset: fileSize)
            try? handle.seek(toOffset: edit.offset)
            try? handle.write(contentsOf: original)
            try? handle.synchronize()
            throw error
        }
        try handle.close()
        MusicAnalysisCache.carryOver(analysisCacheEntry, to: url, in: analysisCacheDirectory)
    }

    private static func isValid(_ edit: InPlaceEdit, fileSize: UInt64) -> Bool {
        let (end, overflow) = edit.offset.addingReportingOverflow(edit.originalLength)
        let isValid = overflow == false && end <= fileSize && edit.originalLength <= UInt64(Int.max)
            && (edit.newFileLength.map { $0 == edit.offset + UInt64(edit.data.count) && end == fileSize }
                ?? (UInt64(edit.data.count) == edit.originalLength))
        assert(isValid, "Invalid in-place edit")
        return isValid
    }

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

import CryptoKit
import Foundation

nonisolated enum MediaImportFingerprint {
    private static let bufferSize = 1_048_576

    static func read(from url: URL) throws -> String {
        try Task.checkCancellation()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            // Release Foundation's temporary data after each bounded read.
            let reachedEnd = try autoreleasepool {
                guard let data = try handle.read(upToCount: bufferSize), !data.isEmpty else {
                    return true
                }
                hasher.update(data: data)
                return false
            }
            if reachedEnd { break }
        }
        try Task.checkCancellation()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)"
    }

    static func fileSize(of url: URL) throws -> UInt64 {
        try Task.checkCancellation()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        try Task.checkCancellation()
        return UInt64(size)
    }
}

import Foundation
import Testing
@testable import SimpleMediaPlayer

struct ManagedFileCopierTests {
    @Test func copiesAFileOnTheSameVolume() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let contents = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        try contents.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let destination = directory.appendingPathComponent("copy.bin")

        try ManagedFileCopier.copy(from: source, to: destination) { false }

        #expect(try Data(contentsOf: destination) == contents)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    }

    @Test func blockCopyStopsOnceAskedAndLeavesOnlyPartOfTheFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let size = 32 * 1_048_576
        try Data(repeating: 0x5A, count: size).write(to: source)
        let destination = directory.appendingPathComponent("copy.bin")
        let checks = CheckCounter()

        // Clones copy no blocks, so this exercises the copy a clone falls back to.
        #expect(throws: CancellationError.self) {
            try ManagedFileCopier.copy(from: source, to: destination, allowsClone: false) { checks.next() >= 2 }
        }

        #expect(checks.count >= 2)
        let written = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
            .intValue ?? 0
        #expect(written < size)
    }

    @Test func errorsFailTheCopyAsWithoutACallbackExceptAnIgnoredQuarantine() {
        func interruption(
            _ what: Int32, _ stage: Int32, _ name: String? = nil, errno: Int32 = ENOSPC, stopped: Bool = false
        ) -> ManagedFileCopier.Interruption? {
            ManagedFileCopier.interruption(
                what: what, stage: stage, attributeName: name, errno: errno, shouldStop: { stopped }
            )
        }
        let data = COPYFILE_COPY_DATA
        let xattr = COPYFILE_COPY_XATTR
        let error = COPYFILE_ERR
        #expect(interruption(data, error) == .failed(errno: ENOSPC))
        #expect(interruption(data, error, errno: 0) == .failed(errno: EIO))
        // Continuing would register a copy whose resource fork or attribute is missing.
        #expect(interruption(xattr, error, "com.apple.ResourceFork") == .failed(errno: ENOSPC))
        #expect(interruption(xattr, error, "com.apple.metadata:kMDItemWhereFroms", errno: EPERM)
            == .failed(errno: EPERM))
        #expect(interruption(xattr, error, nil) == .failed(errno: ENOSPC))
        // copyfile ignores a quarantine it cannot apply when it has no callback, and so does the import.
        #expect(interruption(xattr, error, "com.apple.quarantine", errno: ENOTSUP) == nil)
        for what in [data, xattr] {
            for stage in [COPYFILE_START, COPYFILE_PROGRESS, COPYFILE_FINISH] {
                #expect(interruption(what, stage) == nil)
                #expect(interruption(what, stage, stopped: true) == .stopped)
            }
        }
        // A cancelled import is stopped rather than failed, whatever error the copy also reports.
        #expect(interruption(data, error, stopped: true) == .stopped)
        #expect(interruption(xattr, error, "com.apple.ResourceFork", stopped: true) == .stopped)
        #expect(interruption(xattr, error, "com.apple.quarantine", stopped: true) == .stopped)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

nonisolated private final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    func next() -> Int {
        lock.withLock {
            calls += 1
            return calls
        }
    }
}

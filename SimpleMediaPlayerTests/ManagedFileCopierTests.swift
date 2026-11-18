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

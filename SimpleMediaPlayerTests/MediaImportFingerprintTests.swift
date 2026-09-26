import CryptoKit
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct MediaImportFingerprintTests {
    @Test(arguments: [
        (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    ])
    func matchesKnownSHA256Digests(data: Data, digest: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.mp3")
        try data.write(to: url)

        #expect(try MediaImportFingerprint.read(from: url) == "sha256:\(digest)")
        #expect(try MediaImportFingerprint.fileSize(of: url) == UInt64(data.count))
    }

    @Test(arguments: [1_048_575, 1_048_576, 1_048_577, 3_145_745])
    func hashesAllBytesAcrossReadBoundaries(byteCount: Int) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.wav")
        var data = Data(repeating: 0x3A, count: byteCount)
        data[data.endIndex - 1] = 0xF1
        try data.write(to: url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        #expect(try MediaImportFingerprint.read(from: url) == "sha256:\(expected)")
        #expect(try MediaImportFingerprint.fileSize(of: url) == UInt64(byteCount))
    }

    @Test func identifiesRenamedCopiesAndDistinguishesSameSizeFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mp3")
        let renamed = directory.appendingPathComponent("renamed.mp3")
        let different = directory.appendingPathComponent("different.mp3")
        try Data("same file contents".utf8).write(to: original)
        try FileManager.default.copyItem(at: original, to: renamed)
        try Data("some file contents".utf8).write(to: different)

        let fingerprint = try MediaImportFingerprint.read(from: original)
        #expect(try MediaImportFingerprint.read(from: renamed) == fingerprint)
        #expect(try MediaImportFingerprint.read(from: different) != fingerprint)
        #expect(try MediaImportFingerprint.fileSize(of: original) == MediaImportFingerprint.fileSize(of: different))
    }

    @Test func preservesSourceContentsAndOtherReadersPosition() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.aiff")
        let data = Data("original audio data".utf8)
        try data.write(to: url)
        let otherReader = try FileHandle(forReadingFrom: url)
        defer { try? otherReader.close() }
        try otherReader.seek(toOffset: 4)

        _ = try MediaImportFingerprint.read(from: url)
        _ = try MediaImportFingerprint.fileSize(of: url)

        #expect(try otherReader.offset() == 4)
        #expect(try Data(contentsOf: url) == data)
        #expect(try otherReader.readToEnd() == Data(data.dropFirst(4)))
    }

    @Test func rejectsMissingFileAndDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.mp3")

        #expect(throws: (any Error).self) { try MediaImportFingerprint.read(from: missing) }
        #expect(throws: (any Error).self) { try MediaImportFingerprint.fileSize(of: missing) }
        #expect(throws: (any Error).self) { try MediaImportFingerprint.fileSize(of: directory) }
    }

    @Test func cancellationPreventsReadingAndLeavesSourceIntact() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.mp3")
        let data = Data("cancelled import".utf8)
        try data.write(to: url)

        let reader = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MediaImportFingerprint.read(from: url)
        }
        await #expect(throws: CancellationError.self) { try await reader.value }

        let sizeReader = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MediaImportFingerprint.fileSize(of: url)
        }
        await #expect(throws: CancellationError.self) { try await sizeReader.value }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func readsSparseFileSizeWithoutScanningItsContents() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.wav")
        try Data().write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        let expectedSize: UInt64 = 16 * 1_024 * 1_024 * 1_024
        try writer.truncate(atOffset: expectedSize)

        #expect(try MediaImportFingerprint.fileSize(of: url) == expectedSize)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

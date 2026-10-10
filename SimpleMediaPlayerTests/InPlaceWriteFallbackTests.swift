import Foundation
import Testing
@testable import SimpleMediaPlayer

/// Saves that could fit in place but take the full rewrite instead.
@MainActor
struct InPlaceWriteFallbackTests {
    /// A read-only file cannot be opened for writing, so the save ends as the replacement does. On macOS 27 the
    /// replacement fails too (Cocoa 513 with POSIX 13), as it did before in-place edits existed.
    @Test(arguments: InPlaceTestFormat.allCases)
    func readOnlyFileEndsAsTheReplacementDoes(format: InPlaceTestFormat) throws {
        let fixture = try format.preparedFixture()
        defer { fixture.remove() }
        let reference = try format.preparedFixture()
        defer { reference.remove() }
        try makeReadOnly(fixture)
        defer { restorePermissions(fixture) }
        try makeReadOnly(reference)
        defer { restorePermissions(reference) }
        try #require((try? FileHandle(forUpdating: fixture.url)) == nil, "Opening for writing must fail")
        let original = try Data(contentsOf: fixture.url)
        let draft = titleDraft("Short")

        let expected = Result {
            try MediaFileRewriter.$allowsInPlaceEdits.withValue(false) { try format.write(draft, to: reference.url) }
        }
        let actual = Result { try format.write(draft, to: fixture.url) }

        switch (expected, actual) {
        case (.success, .success):
            #expect(try format.title(at: fixture.url) == "Short")
        case let (.failure(expectedError as NSError), .failure(actualError as NSError)):
            #expect(actualError.domain == expectedError.domain)
            #expect(actualError.code == expectedError.code)
            // The open failure and the replacement failure share the code but not the keys.
            #expect(Set(actualError.userInfo.keys) == Set(expectedError.userInfo.keys))
            #expect(try Data(contentsOf: fixture.url) == original)
        default:
            Issue.record("Expected \(expected), got \(actual)")
        }
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    @Test func updateOfAFileThatCannotBeOpenedForWritingRewritesIt() throws {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-mp3", "mp3"))
        defer { fixture.remove() }
        try makeReadOnly(fixture)
        defer { restorePermissions(fixture) }
        var rewrites = 0

        _ = Result {
            try MediaFileRewriter.update(at: fixture.url, analysisCacheDirectory: nil) { _, _ in
                Issue.record("The file cannot be opened for writing")
                return nil
            } rewrite: { source, output, size in
                rewrites += 1
                try MediaFileRewriter.copy(from: source, range: 0..<size, to: output)
            }
        }

        #expect(rewrites == 1)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    /// A metadata region above the limit is rewritten through the streaming path, not held in memory.
    @Test(arguments: [false, true])
    func flacMetadataAboveTheLimitIsRewritten(exceedsLimit: Bool) throws {
        let fixture = try InPlaceTestFormat.flac.preparedFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.url)
        let metadataEnd = try #require(try flacBlocks(in: original).last).range.upperBound
        let samples = try decodedSamples(at: fixture.url)
        let fileNumber = try fixture.fileNumber()
        let limit = UInt64(metadataEnd - (exceedsLimit ? 1 : 0))

        try FLACMetadataWriter.$inPlaceMetadataLimit.withValue(limit) {
            try InPlaceTestFormat.flac.write(titleDraft("Short"), to: fixture.url)
        }

        let written = try Data(contentsOf: fixture.url)
        let end = try #require(try flacBlocks(in: written).last).range.upperBound
        #expect((try fixture.fileNumber() != fileNumber) == exceedsLimit)
        #expect(written[end...] == original[metadataEnd...])
        #expect(try InPlaceTestFormat.flac.title(at: fixture.url) == "Short")
        #expect(try decodedSamples(at: fixture.url) == samples)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    // MARK: - Helpers

    private func makeReadOnly(_ fixture: InPlaceFixture) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fixture.url.path)
    }

    private func restorePermissions(_ fixture: InPlaceFixture) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url.path)
    }
}

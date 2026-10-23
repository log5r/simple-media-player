import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MetadataWriteInvalidationTests {
    enum Operation: CaseIterable { case lyrics, metadata }
    enum Invalidation: CaseIterable { case deletion, fileName, bookmark }

    @Test(arguments: Operation.allCases, Invalidation.allCases)
    func invalidatedStartedWriteCannotApplyItsResult(operation: Operation, invalidation: Invalidation) async throws {
        let fixture = try MetadataWriteFixture()
        defer { fixture.remove() }
        let write = Task { try await fixture.save(operation) }
        defer { fixture.gate.release() }
        try await fixture.gate.waitUntilWriting()

        switch invalidation {
        case .deletion: fixture.context.delete(fixture.item)
        case .fileName: fixture.item.fileName = fixture.replacementURL.lastPathComponent
        case .bookmark: fixture.item.bookmarkData = Data([1, 2, 3])
        }
        try fixture.context.save()
        fixture.gate.release()

        await #expect(throws: CancellationError.self) { try await write.value }
        let saved = try ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>())
        #expect(saved.count == (invalidation == .deletion ? 0 : 1))
        if let item = saved.first {
            #expect(item.title == MetadataWriteFixture.originalTitle)
            #expect(item.lyricsRaw == MetadataWriteFixture.originalLyrics)
            #expect(!item.hasEditedTextMetadata && !item.hasEditedLyrics)
        }
        #expect(try Data(contentsOf: fixture.replacementURL) == fixture.replacementBytes)
        // The started write may finish on its original file, but must not update a different library reference.
        #expect(try ID3TagWriter.readEmbeddedTag(Data(contentsOf: fixture.sourceURL))?.lyrics == "New lyrics")
        #expect(fixture.gate.finished)
    }

    @Test(arguments: Operation.allCases)
    func cancellationAfterWritingStartsStillSavesTheCurrentItem(operation: Operation) async throws {
        let fixture = try MetadataWriteFixture()
        defer { fixture.remove() }
        let write = Task { try await fixture.save(operation) }
        defer { fixture.gate.release() }
        try await fixture.gate.waitUntilWriting()

        write.cancel()
        fixture.gate.release()
        try await write.value

        let saved = try #require(ModelContext(fixture.container).fetch(FetchDescriptor<MediaItem>()).first)
        #expect(saved.lyricsRaw == "New lyrics")
        #expect(saved.hasEditedLyrics)
        #expect(saved.title == (operation == .metadata ? "New title" : MetadataWriteFixture.originalTitle))
        #expect(try ID3TagWriter.readEmbeddedTag(Data(contentsOf: fixture.sourceURL))?.lyrics == saved.lyricsRaw)
        #expect(fixture.gate.finished)
    }
}

@MainActor
private struct MetadataWriteFixture {
    static let originalTitle = "Original title"
    static let originalLyrics = "Original lyrics"
    let source: InPlaceFixture
    let replacementURL: URL
    let replacementBytes: Data
    let container: ModelContainer
    let item: MediaItem
    let service: LibraryService
    let gate = MetadataWriteGate()
    var sourceURL: URL { source.url }
    var context: ModelContext { container.mainContext }

    init() throws {
        source = try InPlaceTestFormat.mp3.preparedFixture()
        var original = titleDraft(Self.originalTitle)
        original.lyrics = Self.originalLyrics
        original.editsLyrics = true
        try ID3TagWriter.write(original, to: source.url)
        replacementURL = source.directory.appendingPathComponent("replacement.mp3")
        replacementBytes = try Data(contentsOf: source.url)
        try replacementBytes.write(to: replacementURL)
        container = try ModelContainer(
            for: MediaItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        item = MediaItem(
            title: Self.originalTitle, duration: 1, isVideo: false, lyricsRaw: Self.originalLyrics,
            bookmarkData: Data([0xFF]), fileName: source.url.lastPathComponent
        )
        container.mainContext.insert(item)
        try container.mainContext.save()
        let gate = gate
        service = LibraryService(mediaDirectoryURL: source.directory, metadataWriter: { draft, url in
            try MediaFileRewriter.$inPlaceWrite.withValue(gate.write) {
                try LibraryService.writeEmbeddedMetadata(draft, to: url)
            }
        })
    }

    func save(_ operation: MetadataWriteInvalidationTests.Operation) async throws {
        switch operation {
        case .lyrics:
            try await service.saveLyrics("New lyrics", for: item, embedInFile: true, in: context)
        case .metadata:
            var draft = titleDraft("New title")
            draft.lyrics = "New lyrics"
            draft.editsLyrics = true
            try await service.updateEmbeddedMetadata(for: item, draft: draft, in: context)
        }
    }

    func remove() { source.remove() }
}

/// Stops after bytes have actually been written, inside the rewriter's exclusive file lock.
private nonisolated final class MetadataWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var writing = false
    private var didFinish = false
    var finished: Bool { lock.withLock { didFinish } }

    func write(_ handle: FileHandle, _ data: Data) throws {
        let midpoint = data.count / 2
        try handle.write(contentsOf: data.prefix(midpoint))
        lock.withLock { writing = true }
        guard resume.wait(timeout: .now() + 10) == .success else {
            Issue.record("The test did not release the started metadata write")
            throw CocoaError(.fileWriteUnknown)
        }
        try handle.write(contentsOf: data.dropFirst(midpoint))
        lock.withLock { didFinish = true }
    }

    func waitUntilWriting() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !lock.withLock({ writing }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(lock.withLock { writing })
    }

    func release() { resume.signal() }
}

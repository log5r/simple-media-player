import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

/// An item shows `Unknown Artist` and `Unknown Album` both for missing values and for these literal values; an
/// override that could not be embedded must record only the missing ones as empty edits.
@MainActor
struct ImportOverridePlaceholderTests {
    @Test func completeTextOverrideKeepsLiteralPlaceholderText() async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let source = try writeAudio(named: "plain.m4a", in: fixture.directory, formatID: kAudioFormatMPEG4AAC)
        var override = MediaImportOverride(musicLibraryItemID: "110", replacesTextFields: true)
        override.values.title = "Music Title"
        override.values.artist = "Unknown Artist"
        override.values.album = "Unknown Album"

        await fixture.service.importFiles(
            from: [source], overrides: [source: override], into: fixture.context, existingItems: []
        )

        let item = try #require(try fixture.items().first)
        #expect(item.artist == "Unknown Artist")
        #expect(item.album == "Unknown Album")
        #expect(item.hasEditedTextMetadata)
        #expect(item.editedArtist == "Unknown Artist")
        #expect(item.editedAlbum == "Unknown Album")
        let draft = MediaMetadataEditDraft(item: item)
        #expect(draft.artist == "Unknown Artist")
        #expect(draft.album == "Unknown Album")
    }

    /// A partial override keeps the file's artist and album, so the file decides whether they are literal.
    @Test(arguments: [false, true])
    func partialOverrideKeepsLiteralPlaceholderOnlyWhenTheFileHoldsIt(literalInFile: Bool) async throws {
        let fixture = try MusicLibraryFixture()
        defer { fixture.remove() }
        let source = try writeAudio(named: "tagged.m4a", in: fixture.directory, formatID: kAudioFormatMPEG4AAC)
        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(
                title: "File Title", artist: literalInFile ? "Unknown Artist" : "",
                album: literalInFile ? "Unknown Album" : "", genre: ""
            ),
            to: source
        )
        var override = MediaImportOverride(musicLibraryItemID: "111", isEmbeddedInFile: false)
        override.values.title = "Override Title"

        await fixture.service.importFiles(
            from: [source], overrides: [source: override], into: fixture.context, existingItems: []
        )

        let item = try #require(try fixture.items().first)
        #expect(item.artist == "Unknown Artist")
        #expect(item.album == "Unknown Album")
        #expect(item.hasEditedTextMetadata)
        #expect(item.editedArtist == (literalInFile ? "Unknown Artist" : ""))
        #expect(item.editedAlbum == (literalInFile ? "Unknown Album" : ""))
        let reopened = try await fixture.service.editableMetadataDraft(for: item)
        #expect(reopened.artist == (literalInFile ? "Unknown Artist" : ""))
        #expect(reopened.album == (literalInFile ? "Unknown Album" : ""))
    }
}

extension ImportOverridePlaceholderTests {
    @Test(arguments: ["mp3", "m4a", "flac", "wav", "ogg", "opus", "aiff", "m4v", "mov"], PlaceholderSource.allCases)
    func bulkCommentPatchResolvesOnlyUneditedPlaceholders(
        fileExtension: String, source: PlaceholderSource
    ) async throws {
        let fixture = try PlaceholderMetadataFixture(fileExtension: fileExtension, source: source)
        defer { fixture.remove() }
        let result = await fixture.service.updateEmbeddedMetadata(
            for: [fixture.item], patch: MediaMetadataEditPatch(fields: [.comment], draft: MediaMetadataEditDraft(
                title: "", artist: "", album: "", genre: "", comment: "New comment"
            )), in: fixture.context
        )
        #expect(result.updatedCount == 1)
        #expect(result.failedCount == 0)
        let literal = source == .literalInFile
        #expect(fixture.item.editedArtist == (literal ? "Unknown Artist" : ""))
        #expect(fixture.item.editedAlbum == (literal ? "Unknown Album" : ""))
        let reopened = try await fixture.service.editableMetadataDraft(for: fixture.item)
        #expect(reopened.artist == (literal ? "Unknown Artist" : ""))
        #expect(reopened.album == (literal ? "Unknown Album" : ""))
        #expect(reopened.comment == "New comment")
    }

    @Test func replacingArtistDoesNotRestoreItFromTheFile() async throws {
        let fixture = try PlaceholderMetadataFixture(fileExtension: "m4a", source: .literalInFile)
        defer { fixture.remove() }
        let draft = try await fixture.service.itemDraftResolvingPlaceholders(for: fixture.item, patching: [.artist])
        #expect(draft.artist == "")
        #expect(draft.album == "Unknown Album")
    }

    @Test(arguments: PlaceholderReadInvalidation.allCases)
    func placeholderReadChecksIdentityCancellationAndCurrentEdits(
        invalidation: PlaceholderReadInvalidation
    ) async throws {
        let resolver = PlaceholderBlockingResolver()
        let fixture = try PlaceholderMetadataFixture(fileExtension: "mp3", source: .literalInFile, resolver: resolver)
        defer { fixture.remove(); resolver.release() }
        let read = Task { @MainActor in
            try await fixture.service.itemDraftResolvingPlaceholders(for: fixture.item, patching: [.comment])
        }
        defer { read.cancel() }
        try await resolver.waitUntilStarted()
        // Reaching this MainActor operation while resolution is blocked verifies that bookmark I/O is off-actor.
        #expect(resolver.ranOnMainThread == false)
        switch invalidation {
        case .itemID: fixture.item.id = UUID()
        case .bookmark: fixture.item.bookmarkData = Data([0, 1])
        case .fileName: fixture.item.fileName = "replacement.mp3"
        case .deleted: fixture.context.delete(fixture.item)
        case .cancelled: read.cancel()
        case .edited: fixture.item.setEditedTextMetadata(MediaMetadataEditDraft(
            title: "Changed", artist: "", album: "", genre: ""
        ))
        case .artist: fixture.item.artist = "Current artist"
        }
        resolver.release()
        if invalidation == .edited || invalidation == .artist {
            let draft = try await read.value
            #expect(draft.artist == (invalidation == .artist ? "Current artist" : ""))
            #expect(draft.album == (invalidation == .artist ? "Unknown Album" : ""))
        } else {
            await #expect(throws: CancellationError.self) { try await read.value }
        }
    }

    @Test(arguments: [false, true])
    func legacyID3v1ValuesAndID3v2PrecedenceArePreserved(hasV2Artist: Bool) async throws {
        let fixture = try PlaceholderMetadataFixture(fileExtension: "mp3", source: .missingInFile)
        defer { fixture.remove() }
        var data = try Data(contentsOf: InPlaceFixture.resource("untagged-mp3", "mp3"))
        if hasV2Artist {
            let artist = TestID3.frame("TPE1", Data([0]) + Data("V2 artist".utf8), version: 3)
            data = TestID3.tag(version: 3, frames: [artist]) + data
        }
        func padded(_ text: String, count: Int) -> Data {
            let bytes = Data(text.utf8)
            return bytes + Data(count: count - bytes.count)
        }
        data += Data("TAG".utf8) + padded("V1 title", count: 30)
            + padded("Unknown Artist", count: 30) + padded("Unknown Album", count: 30)
            + padded("2026", count: 4) + Data(count: 30) + Data([255])
        try data.write(to: fixture.url)
        let original = try await fixture.service.editableMetadataDraft(for: fixture.item, includesArtwork: false)
        let selected = try await fixture.service.itemDraftResolvingPlaceholders(for: fixture.item, patching: [.comment])
        #expect(original.artist == (hasV2Artist ? "V2 artist" : "Unknown Artist"))
        // AVFoundation uses ID3v1 only when ID3v2 is absent; it does not merge a missing v2 album from v1.
        #expect(original.album == (hasV2Artist ? "" : "Unknown Album"))
        #expect(selected.artist == (hasV2Artist ? "" : "Unknown Artist"))
        #expect(selected.album == original.album)
    }

    @Test func unsupportedNativeID3LayoutKeepsReadableCommonArtistAndAlbum() async throws {
        let fixture = try PlaceholderMetadataFixture(fileExtension: "mp3", source: .missingInFile)
        defer { fixture.remove() }
        let frames = [
            TestID3.frame("TPE1", Data([0]) + Data("Unknown Artist".utf8), version: 3),
            TestID3.frame("TALB", Data([0]) + Data("Unknown Album".utf8), version: 3)
        ]
        var tag = TestID3.tag(version: 3, frames: frames)
        // ID3v2.3 unsynchronization is valid but outside the native reader's supported layouts.
        // These text frames contain no byte sequence that needs unsynchronization.
        tag[5] = 0x80
        let audio = try Data(contentsOf: InPlaceFixture.resource("untagged-mp3", "mp3"))
        try (tag + audio).write(to: fixture.url)
        #expect(throws: MediaMetadataEditError.unsupportedID3Flags) {
            try ID3TagWriter.readMetadata(from: fixture.url, textFields: [.artist, .album])
        }
        let original = try await fixture.service.editableMetadataDraft(for: fixture.item, includesArtwork: false)
        let selected = try await fixture.service.itemDraftResolvingPlaceholders(for: fixture.item, patching: [.comment])
        #expect(original.artist == "Unknown Artist")
        #expect(original.album == "Unknown Album")
        #expect(selected.artist == original.artist)
        #expect(selected.album == original.album)
    }

    @Test func quickTimeKeyedMetadataUsesCommonFallbackEvenWithM4AExtension() async throws {
        let fixture = try PlaceholderMetadataFixture(fileExtension: "m4a", source: .missingInFile)
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.url)
        // AVAssetExportSession generated this valid QuickTime container with com.apple.quicktime.* keys.
        // Use a fixed fixture on both OSes; its legacy meta container has no full-box version/flags prefix.
        let source = try InPlaceFixture.resource("quicktime-keyed-audio", "m4a")
        try FileManager.default.copyItem(at: source, to: fixture.url)
        #expect(try MP4MetadataReader.requiresCommonTextFallback(from: fixture.url))
        #expect(try MP4MetadataReader.read(from: fixture.url, textFields: [.artist, .album]) == nil)
        let original = try await fixture.service.editableMetadataDraft(for: fixture.item, includesArtwork: false)
        let selected = try await fixture.service.itemDraftResolvingPlaceholders(for: fixture.item, patching: [.comment])
        #expect(original.artist == "Unknown Artist")
        #expect(original.album == "Unknown Album")
        #expect(selected.artist == original.artist)
        #expect(selected.album == original.album)
    }

    @Test func selectedNativeReadsSkipArtworkLyricsAndOtherText() throws {
        for ext in ["mp3", "m4a", "flac", "wav", "ogg", "opus"] {
            let fixture = try PlaceholderMetadataFixture(fileExtension: ext, source: .literalInFile)
            defer { fixture.remove() }
            let selected: Set<MediaMetadataEditField> = [.artist, .album]
            let values: MediaMetadataEmbeddedValues
            if ext == "mp3" {
                values = try #require(try ID3TagWriter.readMetadata(from: fixture.url, textFields: selected))
            } else if ext == "m4a" {
                let result = try #require(try MP4MetadataReader.read(from: fixture.url, textFields: selected))
                values = result.values
                #expect(result.artworkData == nil)
                #expect(result.lyrics == nil)
            } else {
                let result = try AdditionalAudioMetadata.read(from: fixture.url, textFields: selected)
                values = result.values
                #expect(result.artworkData == nil)
                #expect(result.lyrics == nil)
            }
            #expect(values.artist == "Unknown Artist")
            #expect(values.album == "Unknown Album")
            #expect(values.title == nil)
            #expect(values.comment == nil)
        }
    }
}

nonisolated enum PlaceholderReadInvalidation: CaseIterable {
    case itemID, bookmark, fileName, deleted, cancelled, edited, artist
}

@MainActor
private struct PlaceholderMetadataFixture {
    let directory: URL
    let url: URL
    let container: ModelContainer
    let item: MediaItem
    let service: LibraryService
    var context: ModelContext { container.mainContext }

    init(fileExtension: String, source: PlaceholderSource, resolver: PlaceholderBlockingResolver? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("source.\(fileExtension)")
        if fileExtension == "aiff" {
            _ = try writeAudio(named: url.lastPathComponent, in: directory, formatID: kAudioFormatLinearPCM)
        } else {
            let resourceName: String
            let resourceExtension: String
            switch fileExtension {
            case "mp3": resourceName = "untagged-mp3"; resourceExtension = "mp3"
            case "m4a", "m4v", "mov": resourceName = "untagged-aac"; resourceExtension = "m4a"
            default: resourceName = "tag-test"; resourceExtension = fileExtension
            }
            try FileManager.default.copyItem(
                at: InPlaceFixture.resource(resourceName, resourceExtension), to: url
            )
        }
        let literal = source != .missingInFile
        let tags = MediaMetadataEditDraft(
            title: "File title", artist: literal ? "Unknown Artist" : "", album: literal ? "Unknown Album" : "",
            genre: "", comment: "Old comment", artworkData: try makeDraftArtwork(), lyrics: "File lyrics",
            editsArtwork: true, editsLyrics: true
        )
        if fileExtension == "mp3" {
            try ID3TagWriter.write(tags, to: url)
        } else if MP4MetadataWriter.canWriteMetadata(to: url) {
            try MP4MetadataWriter.write(tags, to: url)
        } else if fileExtension == "aiff" {
            try AIFFMetadataWriter.write(tags, to: url)
        } else {
            try AdditionalAudioMetadata.write(tags, to: url)
        }
        container = try ModelContainer(
            for: MediaItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        item = MediaItem(
            title: "Model title", duration: 0.1, isVideo: false,
            bookmarkData: Data([0xFF]), fileName: url.lastPathComponent
        )
        if source == .storedEdits { item.setEditedTextMetadata(MediaMetadataEditDraft(item: item)) }
        container.mainContext.insert(item)
        try container.mainContext.save()
        if let resolver {
            service = LibraryService(mediaDirectoryURL: directory, resolveBookmark: resolver.resolve)
        } else {
            service = LibraryService(mediaDirectoryURL: directory)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private nonisolated final class PlaceholderBlockingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false
    private var onMainThread = false
    var ranOnMainThread: Bool { lock.withLock { onMainThread } }

    func resolve(_ bookmark: Data, _ fallback: URL) -> URL {
        lock.withLock { started = true; onMainThread = Thread.isMainThread }
        _ = gate.wait(timeout: .now() + 5)
        return fallback
    }

    func release() { gate.signal() }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while lock.withLock({ started }) == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(lock.withLock { started })
    }
}

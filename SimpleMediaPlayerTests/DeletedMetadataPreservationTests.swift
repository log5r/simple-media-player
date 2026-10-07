import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct DeletedMetadataPreservationTests {
    @Test(arguments: ["", "Replacement lyrics"], [false, true])
    func savedLyricsSurviveStoreAndServiceRecreation(lyrics: String, embedInFile: Bool) async throws {
        let fixture = try DeletedMetadataFixture()
        defer { fixture.remove() }
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(
            schema: schema, url: fixture.directory.appendingPathComponent("library.store"), cloudKitDatabase: .none
        )
        var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
        let itemID = try await saveLyrics(
            lyrics, embedInFile: embedInFile, container: #require(container), fixture: fixture
        )
        container = nil
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let item = try #require(reopened.mainContext.fetch(FetchDescriptor<MediaItem>()).first)
        #expect(item.id == itemID)
        let service = LibraryService(mediaDirectoryURL: fixture.directory, lyricsReader: EmbeddedLyricsReader(
            readAsset: { _ in "Original embedded lyrics" }
        ))

        await service.refreshMissingLyrics(for: item, in: reopened.mainContext)
        let draft = try await service.editableMetadataDraft(for: item)

        #expect(item.lyricsRaw == (lyrics.isEmpty ? nil : lyrics))
        #expect(draft.lyrics == lyrics)
        let sourceLyrics = embedInFile ? (lyrics.isEmpty ? nil : lyrics) : "Original embedded lyrics"
        #expect(try ID3TagWriter.readEmbeddedTag(Data(contentsOf: fixture.url))?.lyrics == sourceLyrics)
    }

    @Test(arguments: [UInt8(2), 3, 4], ["", "Replacement lyrics"])
    func lyricsEditsRemoveBothSynchronizedAndUnsynchronizedFrames(version: UInt8, lyrics: String) throws {
        let fixture = try DeletedMetadataFixture()
        defer { fixture.remove() }
        let synchronizedID = version == 2 ? "SLT" : "SYLT"
        let plainID = version == 2 ? "ULT" : "USLT"
        let unknown = frame(version == 2 ? "UFI" : "UFID", payload: Data([0, 1, 2]), version: version)
        let frames = frame(plainID, payload: Data([0]) + Data("eng\0Old plain lyrics".utf8), version: version)
            + frame(synchronizedID, payload: synchronizedLyrics(), version: version) + unknown
        let audio = try fixture.audio()
        try (tag(frames, version: version) + audio).write(to: fixture.url)
        var edit = draft()
        edit.editsTextMetadata = false
        edit.editsLyrics = true
        edit.lyrics = lyrics

        try ID3TagWriter.write(edit, to: fixture.url)

        let written = try Data(contentsOf: fixture.url)
        let tagEnd = 10 + written[6..<10].reduce(0) { ($0 << 7) | Int($1) }
        #expect(written.range(of: Data(synchronizedID.utf8)) == nil)
        #expect(written.range(of: unknown) != nil)
        #expect(Data(written[tagEnd...]) == audio)
        #expect(try ID3TagWriter.readEmbeddedTag(written)?.lyrics == (lyrics.isEmpty ? nil : lyrics))
    }

    @Test func unrelatedID3TextEditPreservesSynchronizedLyrics() throws {
        let fixture = try DeletedMetadataFixture()
        defer { fixture.remove() }
        let synchronized = frame("SYLT", payload: synchronizedLyrics(), version: 3)
        try (tag(synchronized, version: 3) + fixture.audio()).write(to: fixture.url)

        try ID3TagWriter.write(draft(), to: fixture.url)

        #expect(try Data(contentsOf: fixture.url).range(of: synchronized) != nil)
    }

    @Test(arguments: [false, true])
    func textEditsRemoveAllMP4SortFallbacks(clear: Bool) throws {
        let fixture = try DeletedMetadataFixture(fileExtension: "m4a")
        defer { fixture.remove() }
        let sortTypes = ["sonm", "soar", "soal", "soaa", "soco"]
        let sorted = sortTypes.reduce(Data()) { $0 + metadataItem($1, "Old " + $1) }
        let unknown = metadataItem("----", "Preserved")
        let audioBox = box("mdat", Data([4, 5, 6]))
        let original = box("moov", box("udta", box("meta", Data(repeating: 0, count: 4)
            + box("ilst", sorted + unknown)))) + audioBox
        try original.write(to: fixture.url)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.values.artist == "Old soar")
        var edit = draft()
        edit.title = clear ? "" : "New title"
        edit.artist = clear ? "" : "New artist"
        edit.album = clear ? "" : "New album"
        edit.albumArtist = clear ? "" : "New album artist"
        edit.composer = clear ? "" : "New composer"

        try MP4MetadataWriter.write(edit, to: fixture.url)

        let written = try Data(contentsOf: fixture.url)
        let values = try #require(try MP4MetadataReader.read(from: fixture.url))
        #expect(values.values.title == (clear ? nil : edit.title))
        #expect(values.values.artist == (clear ? nil : edit.artist))
        #expect(values.values.album == (clear ? nil : edit.album))
        #expect(values.values.albumArtist == (clear ? nil : edit.albumArtist))
        #expect(values.values.composer == (clear ? nil : edit.composer))
        #expect(values.usedSortMetadataFallback == false)
        #expect(sortTypes.allSatisfy { written.range(of: Data($0.utf8)) == nil })
        #expect(written.range(of: unknown) != nil)
        #expect(written.suffix(audioBox.count) == audioBox)
    }

    @Test func lyricsOnlyMP4EditPreservesSortMetadata() throws {
        let fixture = try DeletedMetadataFixture(fileExtension: "m4a")
        defer { fixture.remove() }
        let sorted = metadataItem("sonm", "Sort title") + metadataItem("soar", "Sort artist")
        try box("moov", box("udta", box("meta", Data(repeating: 0, count: 4)
            + box("ilst", sorted)))).write(to: fixture.url)
        var edit = draft()
        edit.editsTextMetadata = false
        edit.editsLyrics = true

        try MP4MetadataWriter.write(edit, to: fixture.url)

        #expect(try Data(contentsOf: fixture.url).range(of: sorted) != nil)
    }

    @Test func clearingCommentWithID3v1AndV2KeepsTheEditorEmptyAfterReload() async throws {
        let fixture = try DeletedMetadataFixture()
        defer { fixture.remove() }
        var original = draft()
        original.comment = "Old v2 comment"
        try ID3TagWriter.write(original, to: fixture.url)
        let trailer = Data("TAG".utf8) + padded("Title", count: 30) + padded("Artist", count: 30)
            + padded("Album", count: 30) + Data("2026".utf8) + padded("Old v1 comment", count: 30) + Data([0])
        let source = try Data(contentsOf: fixture.url)
        try (source + trailer).write(to: fixture.url)
        let container = try ModelContainer(for: MediaItem.self, configurations: ModelConfiguration(
            isStoredInMemoryOnly: true
        ))
        let context = container.mainContext
        let service = LibraryService(mediaDirectoryURL: fixture.directory)
        let item = fixture.item()
        item.comment = original.comment
        context.insert(item)
        try context.save()
        let before = try await service.editableMetadataDraft(for: item)
        #expect(before.comment == "Old v2 comment")
        var edit = before
        edit.comment = ""

        try await service.updateEmbeddedMetadata(for: item, draft: edit, in: context)
        let saved = try #require(ModelContext(container).fetch(FetchDescriptor<MediaItem>()).first)
        let reopened = try await LibraryService(mediaDirectoryURL: fixture.directory).editableMetadataDraft(for: saved)

        #expect(saved.comment == nil)
        #expect(reopened.comment.isEmpty)
        #expect(try ID3TagWriter.readMetadata(from: fixture.url)?.comment == nil)
        #expect(try Data(contentsOf: fixture.url).suffix(128) == trailer)
        let asset = AVURLAsset(url: fixture.url)
        var metadata = (try? await asset.load(.commonMetadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            metadata += (try? await asset.loadMetadata(for: format)) ?? []
        }
        var strings: [String] = []
        for value in metadata {
            if let text = try? await value.load(.stringValue) { strings.append(text) }
        }
        print("ID3v1 fallback after clearing v2 comment: \(strings)")
    }

    private func saveLyrics(
        _ lyrics: String, embedInFile: Bool, container: ModelContainer, fixture: DeletedMetadataFixture
    ) async throws -> UUID {
        var embedded = draft()
        embedded.lyrics = "Original embedded lyrics"
        embedded.editsLyrics = true
        try ID3TagWriter.write(embedded, to: fixture.url)
        let item = fixture.item()
        container.mainContext.insert(item)
        try container.mainContext.save()
        try await LibraryService(mediaDirectoryURL: fixture.directory).saveLyrics(
            lyrics, for: item, embedInFile: embedInFile, in: container.mainContext
        )
        return item.id
    }

    private func draft() -> MediaMetadataEditDraft {
        MediaMetadataEditDraft(title: "Title", artist: "Artist", album: "Album", genre: "")
    }

    private func synchronizedLyrics() -> Data {
        Data([0]) + Data("eng".utf8) + Data([2, 1, 0]) + Data("Old synchronized lyrics\0".utf8)
            + Data([0, 0, 0, 0])
    }

    private func frame(_ id: String, payload: Data, version: UInt8) -> Data {
        let size = version == 4 ? synchsafe(payload.count) : integer(payload.count, bytes: version == 2 ? 3 : 4)
        return Data(id.utf8) + size + (version == 2 ? Data() : Data([0, 0])) + payload
    }

    private func tag(_ frames: Data, version: UInt8) -> Data {
        Data([0x49, 0x44, 0x33, version, 0, 0]) + synchsafe(frames.count) + frames
    }

    private func synchsafe(_ value: Int) -> Data {
        Data((0..<4).reversed().map { UInt8((value >> ($0 * 7)) & 0x7F) })
    }

    private func integer(_ value: Int, bytes: Int = 4) -> Data {
        Data((0..<bytes).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }

    private func metadataItem(_ type: String, _ value: String) -> Data {
        box(type, box("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(value.utf8)))
    }

    private func box(_ type: String, _ payload: Data) -> Data {
        integer(payload.count + 8) + Data(type.utf8) + payload
    }

    private func padded(_ value: String, count: Int) -> Data {
        Data(value.utf8) + Data(repeating: 0, count: count - value.utf8.count)
    }
}

@MainActor
private struct DeletedMetadataFixture {
    let directory: URL
    let url: URL

    init(fileExtension: String = "mp3") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("source." + fileExtension)
        if fileExtension == "mp3" {
            let resource = try #require(Bundle(for: DeletedMetadataBundleToken.self).url(
                forResource: "untagged-mp3", withExtension: "mp3"
            ))
            try FileManager.default.copyItem(at: resource, to: url)
        }
    }

    func audio() throws -> Data { try Data(contentsOf: url) }

    func item() -> MediaItem {
        MediaItem(
            title: "Title", duration: 0.1, isVideo: false, bookmarkData: Data([0xFF]), fileName: url.lastPathComponent
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class DeletedMetadataBundleToken {}

extension DeletedMetadataPreservationTests {
    @Test(arguments: ["mp3", "m4a", "wav", "flac"])
    func savedEmptyTextWinsOverAStaleEmbeddedValue(fileExtension: String) async throws {
        let fixture = try DeletedMetadataFixture(fileExtension: fileExtension)
        defer { fixture.remove() }
        if fileExtension != "mp3" {
            let resource = try #require(Bundle(for: DeletedMetadataBundleToken.self).url(
                forResource: fileExtension == "m4a" ? "untagged-aac" : "tag-test", withExtension: fileExtension
            ))
            try FileManager.default.copyItem(at: resource, to: fixture.url)
        }
        let container = try ModelContainer(for: MediaItem.self, configurations: ModelConfiguration(
            isStoredInMemoryOnly: true
        ))
        let item = fixture.item()
        container.mainContext.insert(item)
        try container.mainContext.save()
        let service = LibraryService(mediaDirectoryURL: fixture.directory)
        var edit = draft()
        edit.title = "Saved title"
        edit.artist = ""
        edit.comment = ""
        try await service.updateEmbeddedMetadata(for: item, draft: edit, in: container.mainContext)
        var stale = draft()
        stale.comment = "Stale comment"
        if fileExtension == "mp3" {
            try ID3TagWriter.write(stale, to: fixture.url)
        } else if fileExtension == "m4a" {
            try MP4MetadataWriter.write(stale, to: fixture.url)
        } else {
            try AdditionalAudioMetadata.write(stale, to: fixture.url)
        }

        let saved = try #require(ModelContext(container).fetch(FetchDescriptor<MediaItem>()).first)
        let reopened = try await LibraryService(mediaDirectoryURL: fixture.directory).editableMetadataDraft(for: saved)

        #expect(reopened.title == "Saved title")
        #expect(reopened.artist.isEmpty)
        #expect(reopened.comment.isEmpty)
        let result = await service.updateEmbeddedMetadata(
            for: [item], patch: MediaMetadataEditPatch(fields: [.genre], draft: edit), in: container.mainContext
        )
        #expect(result.updatedCount == 1)
        #expect(item.comment == nil)
        #expect(item.artist == "Unknown Artist")
    }
}

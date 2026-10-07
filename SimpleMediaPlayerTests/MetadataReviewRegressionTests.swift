import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MetadataReviewRegressionTests {
    @Test(arguments: MediaMetadataEditField.allCases)
    func editorSaveRecognizesEveryTextFieldAndArtworkOnlyChanges(field: MediaMetadataEditField) {
        let original = MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "")
        let changes = MediaMetadataEditDraft(
            title: "Title", artist: "Artist", album: "Album", genre: "Genre", year: "2026",
            trackNumber: "1", comment: "Comment", albumArtist: "Album artist", composer: "Composer",
            discNumber: "1", isCompilation: true, artworkData: Data([1, 2, 3])
        )
        let edited = MediaMetadataEditPatch(fields: [field], draft: changes).applying(to: original)

        let saving = edited.forSaving(comparedTo: original)

        #expect(saving.editsTextMetadata == (field != .artwork))
        #expect(saving.editsArtwork == (field == .artwork))
        #expect(saving.artworkData == edited.artworkData)
    }

    @Test(arguments: ["mp3", "m4a"], [false, true])
    func clearedTitleAndLiteralUnknownValuesSurviveReloadAndAnotherSave(
        fileExtension: String, literalUnknownValues: Bool
    ) async throws {
        let fixture = try MetadataReviewFixture(fileExtension: fileExtension)
        defer { fixture.remove() }
        let schema = Schema([MediaItem.self])
        let configuration = ModelConfiguration(
            schema: schema, url: fixture.directory.appendingPathComponent("library.store"), cloudKitDatabase: .none
        )
        try await saveInitialEdit(
            schema: schema, configuration: configuration, fixture: fixture, literal: literalUnknownValues
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let item = try #require(container.mainContext.fetch(FetchDescriptor<MediaItem>()).first)
        let service = LibraryService(mediaDirectoryURL: fixture.directory)
        let original = try await service.editableMetadataDraft(for: item)

        #expect(item.title == "source")
        #expect(original.title.isEmpty)
        #expect(original.artist == (literalUnknownValues ? "Unknown Artist" : ""))
        #expect(original.album == (literalUnknownValues ? "Unknown Album" : ""))
        #expect(MediaMetadataEditDraft(item: item).title.isEmpty)
        #expect(MediaMetadataEditDraft(item: item).artist == original.artist)
        #expect(MediaMetadataEditDraft(item: item).album == original.album)

        var changed = original
        changed.comment = "Unrelated comment change"
        for bulk in [false, true] {
            if bulk {
                let result = await service.updateEmbeddedMetadata(
                    for: [item], patch: MediaMetadataEditPatch(fields: [.comment], draft: changed),
                    in: container.mainContext
                )
                #expect(result.updatedCount == 1)
            } else {
                try await service.updateEmbeddedMetadata(for: item, draft: changed, in: container.mainContext)
            }

            let values = try #require(try fixture.readValues())
            #expect(values.title == nil)
            #expect(values.artist == (literalUnknownValues ? "Unknown Artist" : nil))
            #expect(values.album == (literalUnknownValues ? "Unknown Album" : nil))
            #expect(values.comment == changed.comment)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func artworkSavesChangeMP4TextOnlyWhenRequested(bulk: Bool, changesText: Bool) async throws {
        let fixture = try MetadataReviewFixture(fileExtension: "m4a")
        defer { fixture.remove() }
        let sorted = fixture.sortItems()
        let audio = fixture.box("mdat", Data([1, 2, 3, 4]))
        try (fixture.box("moov", fixture.box("udta", fixture.box("meta", Data(repeating: 0, count: 4)
            + fixture.box("ilst", sorted)))) + audio).write(to: fixture.url)
        let container = try ModelContainer(for: MediaItem.self, configurations: ModelConfiguration(
            isStoredInMemoryOnly: true
        ))
        let item = fixture.item()
        container.mainContext.insert(item)
        try container.mainContext.save()
        let service = LibraryService(mediaDirectoryURL: fixture.directory)
        let before = try #require(try fixture.readValues())
        let original = try await service.editableMetadataDraft(for: item)
        var change = original
        if changesText { change.title = "New title" }
        change.artworkData = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        change.editsArtwork = true

        if bulk {
            let fields: Set<MediaMetadataEditField> = changesText ? [.artwork, .title] : [.artwork]
            let result = await service.updateEmbeddedMetadata(
                for: [item], patch: MediaMetadataEditPatch(fields: fields, draft: change), in: container.mainContext
            )
            #expect(result.updatedCount == 1)
        } else {
            let save = change.forSaving(comparedTo: original)
            #expect(save.editsTextMetadata == changesText)
            try await service.updateEmbeddedMetadata(for: item, draft: save, in: container.mainContext)
        }

        #expect(item.title == (changesText ? "New title" : "Library title"))
        #expect(item.hasEditedTextMetadata == changesText)
        if changesText {
            #expect(try fixture.readValues()?.title == "New title")
        } else {
            #expect(try fixture.readValues() == before)
        }
        let written = try Data(contentsOf: fixture.url)
        #expect((written.range(of: sorted) == nil) == changesText)
        #expect(written.suffix(audio.count) == audio)
        #expect(try MP4MetadataReader.read(from: fixture.url)?.artworkData == change.artworkData)
    }

    private func saveInitialEdit(
        schema: Schema, configuration: ModelConfiguration, fixture: MetadataReviewFixture, literal: Bool
    ) async throws {
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let item = fixture.item()
        container.mainContext.insert(item)
        try container.mainContext.save()
        let draft = MediaMetadataEditDraft(
            title: "", artist: literal ? "Unknown Artist" : "", album: literal ? "Unknown Album" : "", genre: ""
        )
        try await LibraryService(mediaDirectoryURL: fixture.directory).updateEmbeddedMetadata(
            for: item, draft: draft, in: container.mainContext
        )
    }
}

@MainActor
private struct MetadataReviewFixture {
    let directory: URL
    let url: URL

    init(fileExtension: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("source." + fileExtension)
        let resource = try #require(Bundle(for: MetadataReviewBundleToken.self).url(
            forResource: fileExtension == "mp3" ? "untagged-mp3" : "untagged-aac", withExtension: fileExtension
        ))
        try FileManager.default.copyItem(at: resource, to: url)
    }

    func item() -> MediaItem {
        MediaItem(
            title: "Library title", duration: 0.1, isVideo: false,
            bookmarkData: Data([0xFF]), fileName: url.lastPathComponent
        )
    }

    func readValues() throws -> MediaMetadataEmbeddedValues? {
        if url.pathExtension == "mp3" { return try ID3TagWriter.readMetadata(from: url) }
        return try MP4MetadataReader.read(from: url)?.values
    }

    func sortItems() -> Data {
        ["sonm", "soar", "soal", "soaa", "soco"].reduce(Data()) { result, type in
            result + box(type, box("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(("Old " + type).utf8)))
        }
    }

    func box(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(payload.count + 8)
        return Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) }) + Data(type.utf8) + payload
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class MetadataReviewBundleToken {}

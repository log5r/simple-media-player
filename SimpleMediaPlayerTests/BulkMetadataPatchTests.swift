import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

/// The bulk path writes only the patched fields to the file and the item, without reading the file's tags.
@MainActor
struct BulkMetadataPatchTests {
    @Test func bulkPatchLeavesUnpatchedFileAndModelFieldsAlone() async throws {
        let audio = try Data(contentsOf: InPlaceFixture.resource("untagged-mp3", "mp3"))
        // The file has no album, while the item has one; the file's title and track differ from the item's.
        let frames = [
            TestID3.frame("TIT2", Data([0]) + Data("File title".utf8), version: 3),
            TestID3.frame("TRCK", Data([0]) + Data("3/12".utf8), version: 3),
            TestID3.frame("TDRC", Data([0]) + Data("2020-05-01".utf8), version: 3),
            TestID3.frame("COMM", Data([0]) + Data("eng".utf8) + Data([0]) + Data("File comment".utf8), version: 3)
        ]
        let fixture = try TemporaryTagFile(TestID3.tag(version: 3, frames: frames) + audio, fileExtension: "mp3")
        defer { fixture.remove() }
        let container = try ModelContainer(for: MediaItem.self, configurations: ModelConfiguration(
            isStoredInMemoryOnly: true
        ))
        let item = MediaItem(
            title: "Model title", artist: "Model artist", album: "Model album", comment: "Model comment",
            duration: 0.1, isVideo: false, bookmarkData: Data([0xFF]), fileName: fixture.url.lastPathComponent
        )
        container.mainContext.insert(item)
        try container.mainContext.save()
        let service = LibraryService(mediaDirectoryURL: fixture.directory)
        var reports: [BulkMetadataEditProgress] = []

        let result = await service.updateEmbeddedMetadata(
            for: [item], patch: MediaMetadataEditPatch(fields: [.comment], draft: PatchValues.patch),
            in: container.mainContext
        ) { reports.append($0) }

        #expect(result.updatedCount == 1)
        #expect(result.failedCount == 0)
        #expect(reports == [BulkMetadataEditProgress(completedCount: 1, totalCount: 1)])
        let values = try #require(try ID3TagWriter.readMetadata(from: fixture.url))
        #expect(values.album == nil)
        #expect(values.artist == nil)
        #expect(values.title == "File title")
        #expect(values.trackNumber == "3/12")
        #expect(values.comment == "New comment")
        let after = try TestID3.parse(Data(contentsOf: fixture.url))
        #expect(after.excluding(["COMM"]) == (try TestID3.parse(fixture.originalData)).excluding(["COMM"]))

        let persisted = try #require(ModelContext(container).fetch(FetchDescriptor<MediaItem>()).first)
        for model in [item, persisted] {
            #expect(model.comment == "New comment")
            #expect(model.title == "Model title")
            #expect(model.artist == "Model artist")
            #expect(model.album == "Model album")
            #expect(model.trackNumber == nil)
            #expect(model.year == nil)
            #expect(model.hasEditedTextMetadata)
            // The recorded edits are the values the item shows, not the file's unpatched values.
            #expect(MediaMetadataEditDraft(item: model).title == "Model title")
            #expect(MediaMetadataEditDraft(item: model).album == "Model album")
        }
    }

    @Test func bulkPatchOfAModelFieldUpdatesOnlyThatFieldInBothPlaces() async throws {
        let audio = try Data(contentsOf: InPlaceFixture.resource("untagged-mp3", "mp3"))
        let fixture = try TemporaryTagFile(
            TestID3.tag(version: 4, frames: TestID3.frames(version: 4)) + audio, fileExtension: "mp3"
        )
        defer { fixture.remove() }
        let container = try ModelContainer(for: MediaItem.self, configurations: ModelConfiguration(
            isStoredInMemoryOnly: true
        ))
        let item = MediaItem(
            title: "Model title", artist: "Model artist", album: "Model album", year: "1999", trackNumber: "1",
            duration: 0.1, isVideo: false, bookmarkData: Data([0xFF]), fileName: fixture.url.lastPathComponent
        )
        container.mainContext.insert(item)
        try container.mainContext.save()
        var patch = PatchValues.patch
        patch.album = "Bulk album"

        let result = await LibraryService(mediaDirectoryURL: fixture.directory).updateEmbeddedMetadata(
            for: [item], patch: MediaMetadataEditPatch(fields: [.album, .trackNumber], draft: patch),
            in: container.mainContext
        )

        #expect(result.updatedCount == 1)
        #expect(item.album == "Bulk album")
        #expect(item.trackNumber == "7/9")
        #expect(item.title == "Model title")
        #expect(item.year == "1999")
        #expect(item.editedAlbum == "Bulk album")
        let patchedIDs: Set<String> = ["TALB", "TRCK"]
        let after = try TestID3.parse(Data(contentsOf: fixture.url))
        #expect(after.excluding(patchedIDs) == (try TestID3.parse(fixture.originalData)).excluding(patchedIDs))
        let values = try #require(try ID3TagWriter.readMetadata(from: fixture.url))
        #expect(values.album == "Bulk album")
        #expect(values.trackNumber == "7/9")
        #expect(values.title == "Old title")
    }
}

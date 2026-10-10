import AVFoundation
import Foundation
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

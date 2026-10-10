import Foundation
import Testing
@testable import SimpleMediaPlayer

/// A bulk patch replaces only its fields in the file. The other text, the lyrics, and the artwork keep their exact
/// bytes, including forms the writers would normalize, and item values for unpatched fields never reach the file.
@MainActor
struct PatchOnlyMetadataWriteTests {
    @Test(arguments: [UInt8(2), 3, 4], [MediaMetadataEditField.comment, .trackNumber])
    func mp3PatchReplacesOnlyItsFrames(version: UInt8, field: MediaMetadataEditField) throws {
        let audio = try Data(contentsOf: InPlaceFixture.resource("untagged-mp3", "mp3"))
        let fixture = try TemporaryTagFile(
            TestID3.tag(version: version, frames: TestID3.frames(version: version)) + audio, fileExtension: "mp3"
        )
        defer { fixture.remove() }
        let before = try TestID3.parse(fixture.originalData)

        try ID3TagWriter.write(PatchValues.draft(patching: field), to: fixture.url)

        let written = try Data(contentsOf: fixture.url)
        let after = try TestID3.parse(written)
        let patchedIDs = TestID3.ids(for: field, version: version)
        #expect(after.excluding(patchedIDs) == before.excluding(patchedIDs))
        #expect(after.including(patchedIDs).count == 1)
        PatchValues.expectWritten(field, in: try ID3TagWriter.readMetadata(from: fixture.url))
        #expect(written.suffix(audio.count) == audio)
    }

    /// The default draft still replaces every editable frame, as the single-item editor expects.
    @Test(arguments: [UInt8(2), 3, 4])
    func mp3DefaultDraftReplacesEveryTextFrame(version: UInt8) throws {
        let audio = try Data(contentsOf: InPlaceFixture.resource("untagged-mp3", "mp3"))
        let fixture = try TemporaryTagFile(
            TestID3.tag(version: version, frames: TestID3.frames(version: version)) + audio, fileExtension: "mp3"
        )
        defer { fixture.remove() }
        let kept: Set<String> = ["ULT", "USLT", "PIC", "APIC", "TXXX"]
        let before = try TestID3.parse(fixture.originalData)

        try ID3TagWriter.write(PatchValues.item, to: fixture.url)

        let after = try TestID3.parse(Data(contentsOf: fixture.url))
        #expect(after.including(kept) == before.including(kept))
        let values = try #require(try ID3TagWriter.readMetadata(from: fixture.url))
        #expect(values.title == "Model title")
        #expect(values.album == nil)
        #expect(values.trackNumber == "1")
        #expect(after.filter { $0.key.hasPrefix("TP1") || $0.key == "TPE1" }.count == 1)
    }

    @Test(arguments: [MediaMetadataEditField.comment, .trackNumber])
    func aiffPatchReplacesOnlyItsFrames(field: MediaMetadataEditField) throws {
        let common = TestChunks.chunk(
            "COMM", Data([0, 1, 0, 0, 0, 0, 0, 16, 0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]), bigEndian: true
        )
        let sound = TestChunks.chunk("SSND", Data(count: 8) + Data([1, 2, 3, 4]), bigEndian: true)
        let id3 = TestChunks.chunk("ID3 ", TestID3.tag(version: 3, frames: TestID3.frames(version: 3)), bigEndian: true)
        let body = Data("AIFF".utf8) + common + id3 + sound
        let fixture = try TemporaryTagFile(
            Data("FORM".utf8) + bigEndian(body.count, byteCount: 4) + body, fileExtension: "aiff"
        )
        defer { fixture.remove() }

        try AIFFMetadataWriter.write(PatchValues.draft(patching: field), to: fixture.url)

        let chunks = try TestChunks.parse(Data(contentsOf: fixture.url), bigEndian: true)
        #expect(chunks.excluding(["ID3 "]).map(\.bytes) == [common, sound])
        let tag = try #require(chunks.including(["ID3 "]).first).bytes.dropFirst(8)
        let patchedIDs = TestID3.ids(for: field, version: 3)
        let before = try TestID3.parse(id3.dropFirst(8))
        let after = try TestID3.parse(Data(tag))
        #expect(after.excluding(patchedIDs) == before.excluding(patchedIDs))
        #expect(after.including(patchedIDs).count == 1)
    }

    @Test(arguments: [MediaMetadataEditField.comment, .trackNumber, .albumArtist])
    func wavPatchReplacesOnlyItsEntriesAndFrames(field: MediaMetadataEditField) throws {
        let fixtureURL = try InPlaceFixture.resource("tag-test", "wav")
        let source = try TestChunks.parse(Data(contentsOf: fixtureURL), bigEndian: false)
        let format = try #require(source.including(["fmt "]).first).bytes
        let audio = try #require(source.including(["data"]).first).bytes
        let entries = [("INAM", "Old title"), ("IART", "Artist A"), ("ICRD", "2020-05-01"), ("ITRK", "3/12"),
                       ("ICMT", "Old comment"), ("ISFT", "Encoder")]
        let info = TestChunks.chunk("LIST", entries.reduce(Data("INFO".utf8)) {
            $0 + TestChunks.chunk($1.0, Data($1.1.utf8) + Data([0]), bigEndian: false)
        }, bigEndian: false)
        let tag = TestID3.tag(version: 3, frames: TestID3.frames(version: 3))
        let id3 = TestChunks.chunk("id3 ", tag, bigEndian: false)
        let body = Data("WAVE".utf8) + format + info + audio + id3
        let fixture = try TemporaryTagFile(Data("RIFF".utf8) + littleEndian32(body.count) + body, fileExtension: "wav")
        defer { fixture.remove() }

        try WAVMetadataWriter.write(PatchValues.draft(patching: field), to: fixture.url)

        let chunks = try TestChunks.parse(Data(contentsOf: fixture.url), bigEndian: false)
        #expect(chunks.map(\.key) == ["fmt ", "LIST", "data", "id3 "])
        #expect(chunks.excluding(["LIST", "id3 "]).map(\.bytes) == [format, audio])
        let infoIDs: Set<String> = field == .comment ? ["ICMT"] : field == .trackNumber ? ["ITRK"] : []
        let infoBefore = try infoEntries(info)
        let infoAfter = try infoEntries(#require(chunks.including(["LIST"]).first).bytes)
        #expect(infoAfter.excluding(infoIDs) == infoBefore.excluding(infoIDs))
        #expect(infoAfter.including(infoIDs).count == infoIDs.count)
        let patchedIDs = TestID3.ids(for: field, version: 3)
        let before = try TestID3.parse(id3.dropFirst(8))
        let after = try TestID3.parse(Data(try #require(chunks.including(["id3 "]).first).bytes.dropFirst(8)))
        #expect(after.excluding(patchedIDs) == before.excluding(patchedIDs))
        PatchValues.expectWritten(field, in: try WAVMetadataWriter.read(from: fixture.url).values)
    }

    @Test(arguments: [MediaMetadataEditField.comment, .trackNumber])
    func m4aPatchReplacesOnlyItsItems(field: MediaMetadataEditField) throws {
        let audio = mp4Box("mdat", Data([1, 2, 3, 4]))
        let items = Self.mp4Items
        let ilst = latin1Box("ilst", items.reduce(Data(), +))
        let fixture = try TemporaryTagFile(
            latin1Box("moov", latin1Box("udta", latin1Box("meta", Data(count: 4) + ilst))) + audio,
            fileExtension: "m4a"
        )
        defer { fixture.remove() }

        try MP4MetadataWriter.write(PatchValues.draft(patching: field), to: fixture.url)

        let written = try Data(contentsOf: fixture.url)
        let meta = try mp4Box(["moov", "udta", "meta"], in: written)
        let metaChildren = try parsedMP4Boxes(in: written, range: (meta.contentStart + 4)..<meta.range.upperBound)
        let ilstAfter = try #require(metaChildren.first { $0.type == "ilst" })
        let after = try parsedMP4Boxes(in: written, range: ilstAfter.contentStart..<ilstAfter.range.upperBound)
            .map { RawTagEntry(key: $0.type, bytes: Data(written[$0.range])) }
        let before = try parsedMP4Boxes(in: ilst, range: 8..<ilst.count)
            .map { RawTagEntry(key: $0.type, bytes: Data(ilst[$0.range])) }
        let patchedTypes: Set<String> = field == .comment ? ["\u{A9}cmt"] : ["trkn"]
        #expect(after.excluding(patchedTypes) == before.excluding(patchedTypes))
        #expect(after.including(patchedTypes).count == 1)
        PatchValues.expectWritten(field, in: try MP4MetadataReader.read(from: fixture.url)?.values)
        #expect(written.suffix(audio.count) == audio)
    }

    @Test(arguments: [MediaMetadataEditField.comment, .trackNumber])
    func flacPatchReplacesOnlyItsFields(field: MediaMetadataEditField) throws {
        let original = try Data(contentsOf: InPlaceFixture.resource("tag-test", "flac"))
        let blocks = try flacBlocks(in: original)
        let picture = try XiphMetadata.pictureBlock(PatchValues.artwork).base64EncodedString()
        let comment = XiphMetadata.Comment(
            vendor: Data("test".utf8),
            fields: (TestXiph.fields + ["METADATA_BLOCK_PICTURE=\(picture)"]).map { Data($0.utf8) }
        )
        let commentData = try XiphMetadata.encode(comment)
        var file = Data(original[..<blocks[1].range.lowerBound])
        file += Data([4]) + bigEndian(commentData.count, byteCount: 3) + commentData
        file += original[blocks[1].range.upperBound...]
        let fixture = try TemporaryTagFile(file, fileExtension: "flac")
        defer { fixture.remove() }

        try AdditionalAudioMetadata.write(PatchValues.draft(patching: field), to: fixture.url)

        let written = try Data(contentsOf: fixture.url)
        let commentBlock = try #require(try flacBlocks(in: written).first { $0.type == 4 })
        let parsed = try XiphMetadata.parse(Data(written[commentBlock.range].dropFirst(4)))
        let keys = TestXiph.keys(for: field)
        #expect(parsed.vendor == comment.vendor)
        #expect(TestXiph.entries(parsed).excluding(keys) == TestXiph.entries(comment).excluding(keys))
        PatchValues.expectWritten(field, in: try AdditionalAudioMetadata.read(from: fixture.url).values)
        let audioStart = try #require(try flacBlocks(in: written).last).range.upperBound
        let originalAudioStart = try #require(blocks.last).range.upperBound
        #expect(written[audioStart...] == original[originalAudioStart...])
    }

    /// The Ogg writer shares the FLAC path's comment update; the fields start in the writer's own forms here.
    @Test(arguments: ["ogg", "opus"], [MediaMetadataEditField.comment, .trackNumber])
    func oggPatchReplacesOnlyItsFields(fileExtension: String, field: MediaMetadataEditField) throws {
        let fixture = try TemporaryTagFile(
            Data(contentsOf: InPlaceFixture.resource("tag-test", fileExtension)), fileExtension: fileExtension
        )
        defer { fixture.remove() }
        var full = MediaMetadataEditDraft(
            title: "Old title", artist: "Old artist", album: "Old album", genre: "Old genre", year: "2020-05-01",
            trackNumber: "3/12", comment: "Old comment", albumArtist: "Old album artist", discNumber: "1/2",
            artworkData: PatchValues.artwork, lyrics: "Old lyrics", editsArtwork: true, editsLyrics: true
        )
        full.isCompilation = true
        try OggMetadataWriter.write(full, to: fixture.url)
        let before = try TestXiph.oggComment(in: Data(contentsOf: fixture.url))

        try OggMetadataWriter.write(PatchValues.draft(patching: field), to: fixture.url)

        let after = try TestXiph.oggComment(in: Data(contentsOf: fixture.url))
        let keys = TestXiph.keys(for: field)
        #expect(TestXiph.entries(after).excluding(keys) == TestXiph.entries(before).excluding(keys))
        PatchValues.expectWritten(field, in: try OggMetadataWriter.read(from: fixture.url).values)
    }

    @Test func draftsReplaceEveryTextFieldUnlessAPatchNamesThem() {
        let all = MediaMetadataEditDraft.allTextFields
        #expect(all == Set(MediaMetadataEditField.allCases).subtracting([.artwork]))
        let draft = MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "")
        #expect(draft.textFields == all)
        #expect(draft.applying(MediaMetadataEmbeddedValues(title: "Embedded")).textFields == all)
        #expect(MediaMetadataEditPatch(draft: draft).applying(to: draft).textFields == all)
        let patched = MediaMetadataEditPatch(fields: [.artwork, .comment], draft: draft).applying(to: draft)
        #expect(patched.textFields == [.comment])
        #expect(patched.editsTextMetadata)
        #expect(patched.applying(MediaMetadataEmbeddedValues()).textFields == [.comment])
        #expect(MediaMetadataEditPatch(fields: [.artwork], draft: draft).applying(to: draft).editsTextMetadata == false)
    }

    private static var mp4Items: [Data] {
        let text = { (type: String, value: String) in
            latin1Box(type, latin1Box("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(value.utf8)))
        }
        return [
            text("\u{A9}nam", "Old title"), text("\u{A9}ART", "Artist A"), text("\u{A9}ART", "Artist B"),
            text("\u{A9}alb", "Old album"), text("\u{A9}day", "2020-05-01"),
            latin1Box("trkn", latin1Box("data", Data(count: 8) + Data([0, 0, 0, 3, 0, 12, 0, 0]))),
            text("aART", "Old album artist"), text("sonm", "Sort title"), text("soar", "Sort artist"),
            text("\u{A9}cmt", "Old comment"), text("\u{A9}lyr", "Old lyrics"),
            latin1Box("covr", latin1Box("data", Data([0, 0, 0, 14, 0, 0, 0, 0]) + PatchValues.artwork)),
            text("\u{A9}too", "Encoder")
        ]
    }

    /// The entries of a LIST chunk, whose 12-byte "LIST", size, and "INFO" header matches a RIFF header's length.
    private func infoEntries(_ chunk: Data) throws -> [RawTagEntry] {
        try TestChunks.parse(Data(chunk), bigEndian: false)
    }
}

/// A box whose type may contain the © byte, which `mp4Box(_:_:)` would encode as two UTF-8 bytes.
nonisolated func latin1Box(_ type: String, _ payload: Data) -> Data {
    bigEndian(payload.count + 8, byteCount: 4) + (type.data(using: .isoLatin1) ?? Data()) + payload
}

/// A file with `data` in its own directory.
nonisolated struct TemporaryTagFile {
    let directory: URL
    let url: URL
    let originalData: Data

    init(_ data: Data, fileExtension: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("source").appendingPathExtension(fileExtension)
        originalData = data
        try data.write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

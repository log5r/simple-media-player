import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct AdditionalAudioMetadataReviewTests {
    @Test func wavInfoEditPreservesUnrelatedSubchunks() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: target) }
        var source = try Data(contentsOf: fixture("wav"))
        let copyright = riffChunk("ICOP", payload: Data("Copyright 2026\0".utf8))
        let software = riffChunk("ISFT", payload: Data("Other encoder\0".utf8))
        let oldTitle = riffChunk("INAM", payload: Data("Old title\0".utf8))
        source += riffChunk("LIST", payload: Data("INFO".utf8) + copyright + oldTitle)
        source += riffChunk("LIST", payload: Data("INFO".utf8) + software)
        source.replaceSubrange(4..<8, with: XiphMetadata.little32(UInt32(source.count - 8)))
        try source.write(to: target)

        try WAVMetadataWriter.write(
            MediaMetadataEditDraft(title: "New title", artist: "", album: "", genre: ""), to: target
        )

        let written = try Data(contentsOf: target)
        #expect(written.range(of: copyright) != nil)
        #expect(written.range(of: software) != nil)
        #expect(written.range(of: oldTitle) == nil)
        #expect(try WAVMetadataWriter.read(from: target).values.title == "New title")
    }

    @Test func wavReadFindsNonblankTagsAcrossMultipleINFOLists() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: target) }
        var source = try Data(contentsOf: fixture("wav"))
        let firstStart = try #require(source.range(of: Data("LIST".utf8))?.lowerBound)
        let firstLength = Int(XiphMetadata.uint32(source, at: firstStart + 4, little: true))
        let firstEnd = firstStart + 8 + firstLength + firstLength % 2
        let blankTitle = riffChunk("INAM", payload: Data([0]))
        let software = riffChunk("ISFT", payload: Data("Encoder\0".utf8))
        source.replaceSubrange(
            firstStart..<firstEnd, with: riffChunk("LIST", payload: Data("INFO".utf8) + blankTitle + software)
        )
        let laterTitle = riffChunk("INAM", payload: Data("Later title\0".utf8))
        source += riffChunk("LIST", payload: Data("INFO".utf8) + laterTitle)
        source.replaceSubrange(4..<8, with: XiphMetadata.little32(UInt32(source.count - 8)))
        try source.write(to: target)

        #expect(try WAVMetadataWriter.read(from: target).values.title == "Later title")
    }

    @Test func flacArtworkEditPreservesOtherCommentPictures() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: target) }
        var source = try Data(contentsOf: fixture("flac"))
        let backCover = try XiphMetadata.pictureBlock(Data([1, 2, 3]))
        var backBlock = backCover
        backBlock[3] = 4
        let backField = Data("METADATA_BLOCK_PICTURE=\(backBlock.base64EncodedString())".utf8)
        let frontField = Data("METADATA_BLOCK_PICTURE=\(try XiphMetadata.pictureBlock(Data([4, 5, 6])).base64EncodedString())".utf8)
        var comment = try flacComment(in: source)
        comment.fields += [backField, frontField]
        try replaceFlacComment(in: &source, with: comment)
        try source.write(to: target)

        let newArtwork = Data([7, 8, 9])
        try FLACMetadataWriter.write(
            MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "",
                                   artworkData: newArtwork, editsTextMetadata: false, editsArtwork: true),
            to: target
        )

        let updated = try flacComment(in: Data(contentsOf: target))
        #expect(updated.fields.contains(backField))
        #expect(updated.fields.contains(frontField) == false)
        #expect(try FLACMetadataWriter.read(from: target).artworkData == newArtwork)
    }

    @Test(arguments: [("flac", ""), ("flac", " \t "), ("wav", ""), ("wav", " \t ")])
    func importFallsBackWhenEmbeddedCoreFieldsAreBlank(fileExtension: String, embeddedTitle: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Filename fallback.\(fileExtension)")
        var data = try Data(contentsOf: fixture(fileExtension))
        if fileExtension == "flac" {
            var comment = try flacComment(in: data)
            comment.fields.removeAll {
                let field = String(data: $0, encoding: .utf8)?.uppercased() ?? ""
                return ["TITLE=", "ARTIST=", "ALBUM="].contains { field.hasPrefix($0) }
            }
            comment.fields += [
                Data("TITLE=\(embeddedTitle)".utf8), Data("ARTIST=".utf8), Data("ALBUM= \t ".utf8)
            ]
            try replaceFlacComment(in: &data, with: comment)
        } else {
            try data.write(to: source)
            try WAVMetadataWriter.write(
                MediaMetadataEditDraft(title: "", artist: "", album: "", genre: ""), to: source
            )
            data = try Data(contentsOf: source)
            let title = riffChunk("INAM", payload: Data(embeddedTitle.utf8) + Data([0]))
            let artist = riffChunk("IART", payload: Data([0]))
            let album = riffChunk("IPRD", payload: Data(" \t \0".utf8))
            let infoStart = try #require(data.range(of: Data("LIST".utf8))?.lowerBound)
            let infoLength = Int(XiphMetadata.uint32(data, at: infoStart + 4, little: true))
            let infoPayload = Data(data[(infoStart + 8)..<(infoStart + 8 + infoLength)])
            #expect(infoPayload.starts(with: Data("INFO".utf8)))
            let infoEnd = infoStart + 8 + infoLength + infoLength % 2
            let updatedInfo = riffChunk("LIST", payload: infoPayload + title + artist + album)
            data.replaceSubrange(infoStart..<infoEnd, with: updatedInfo)
            data.replaceSubrange(4..<8, with: XiphMetadata.little32(UInt32(data.count - 8)))
        }
        try data.write(to: source)
        let embedded = try AdditionalAudioMetadata.read(from: source).values
        #expect(embedded.title == nil)
        #expect(embedded.artist == nil)
        #expect(embedded.album == nil)

        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let service = LibraryService(mediaDirectoryURL: directory.appendingPathComponent("Managed"))
        await service.importFiles(from: [source], into: container.mainContext, existingItems: [])

        let item = try #require(container.mainContext.fetch(FetchDescriptor<MediaItem>()).first)
        #expect(service.lastImportErrors.isEmpty)
        #expect(item.title == "Filename fallback")
        #expect(item.artist == "Unknown Artist")
        #expect(item.album == "Unknown Album")
        let editable = try await service.editableMetadataDraft(for: item)
        #expect(editable.title == item.title)
        #expect(editable.artist == "")
        #expect(editable.album == "")
    }

    @Test func blankPrimaryXiphLyricsUseFallbackTag() {
        let comment = XiphMetadata.Comment(vendor: Data("Encoder".utf8), fields: [
            Data("LYRICS= \t ".utf8), Data("UNSYNCEDLYRICS=Fallback lyrics".utf8)
        ])
        #expect(XiphMetadata.read(comment).lyrics == "Fallback lyrics")

        let preferred = XiphMetadata.Comment(vendor: comment.vendor, fields: [
            Data("LYRICS=Primary lyrics".utf8), Data("UNSYNCEDLYRICS=Fallback lyrics".utf8)
        ])
        #expect(XiphMetadata.read(preferred).lyrics == "Primary lyrics")
    }

    @Test func xiphBlankFieldsDoNotHideLaterValues() {
        let comment = XiphMetadata.Comment(vendor: Data("Encoder".utf8), fields: [
            Data("TITLE=".utf8), Data("TITLE=Later title".utf8),
            Data("DATE= \t".utf8), Data("YEAR=2026".utf8),
            Data("ALBUMARTIST=".utf8), Data("ALBUM ARTIST=Later artist".utf8),
            Data("COMPILATION= ".utf8)
        ])
        let values = XiphMetadata.read(comment).values
        #expect(values.title == "Later title")
        #expect(values.year == "2026")
        #expect(values.albumArtist == "Later artist")
        #expect(values.isCompilation == nil)

        let compilation = XiphMetadata.Comment(vendor: comment.vendor, fields: [
            Data("COMPILATION= YES ".utf8)
        ])
        #expect(XiphMetadata.read(compilation).values.isCompilation == true)
    }

    @Test func blankEmbeddedValuesPreserveDraftFallbacks() {
        let original = MediaMetadataEditDraft(
            title: "Fallback title", artist: "Fallback artist", album: "Fallback album", genre: "Fallback genre",
            year: "2026", trackNumber: "2", comment: "Fallback comment", albumArtist: "Fallback album artist",
            composer: "Fallback composer", discNumber: "1"
        )
        let embedded = MediaMetadataEmbeddedValues(
            title: "", artist: " \t ", album: "", genre: " ", year: "", trackNumber: " ",
            comment: "", albumArtist: " ", composer: "", discNumber: " \n"
        )
        #expect(original.applying(embedded) == original)
    }

    @Test func malformedOptionalWAVTagsDoNotBlockImportOrAssetLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Playable.wav")
        var data = try Data(contentsOf: fixture("wav"))
        let infoStart = try #require(data.range(of: Data("LIST".utf8))?.lowerBound)
        #expect(Data(data[(infoStart + 8)..<(infoStart + 12)]) == Data("INFO".utf8))
        data.replaceSubrange((infoStart + 16)..<(infoStart + 20), with: XiphMetadata.little32(UInt32.max))
        try data.write(to: source)
        #expect(AdditionalAudioMetadata.canWrite(to: source))
        #expect(throws: MediaMetadataEditError.invalidAudioMetadata) {
            try AdditionalAudioMetadata.read(from: source)
        }

        let lyricsReader = EmbeddedLyricsReader(readAsset: { _ in "Asset lyrics" })
        #expect(try await lyricsReader.read(from: source) == "Asset lyrics")

        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let service = LibraryService(mediaDirectoryURL: directory.appendingPathComponent("Managed"))
        await service.importFiles(from: [source], into: container.mainContext, existingItems: [])
        #expect(service.lastImportErrors.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<MediaItem>()).count == 1)
    }

    private func fixture(_ ext: String) -> URL {
        if let bundled = Bundle.allBundles.compactMap({ $0.url(forResource: "tag-test", withExtension: ext) }).first {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tag-test.\(ext)")
    }
}

private func riffChunk(_ id: String, payload: Data) -> Data {
    var chunk = Data(id.utf8) + XiphMetadata.little32(UInt32(payload.count)) + payload
    if payload.count % 2 != 0 { chunk.append(0) }
    return chunk
}

private func flacComment(in data: Data) throws -> XiphMetadata.Comment {
    var cursor = 4
    while cursor + 4 <= data.count {
        let header = data[cursor]
        let length = Int(data[cursor + 1]) << 16 | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
        if header & 0x7f == 4 {
            return try XiphMetadata.parse(Data(data[(cursor + 4)..<(cursor + 4 + length)]))
        }
        cursor += 4 + length
        if header & 0x80 != 0 { break }
    }
    throw MediaMetadataEditError.invalidAudioMetadata
}

private func replaceFlacComment(in data: inout Data, with comment: XiphMetadata.Comment) throws {
    var cursor = 4
    while cursor + 4 <= data.count {
        let header = data[cursor]
        let length = Int(data[cursor + 1]) << 16 | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
        if header & 0x7f == 4 {
            let payload = try XiphMetadata.encode(comment)
            let count = payload.count
            guard count <= 0xFFFFFF else { throw MediaMetadataEditError.invalidAudioMetadata }
            data.replaceSubrange(cursor..<(cursor + 4 + length), with: Data([
                header, UInt8(count >> 16), UInt8((count >> 8) & 0xff), UInt8(count & 0xff)
            ]) + payload)
            return
        }
        cursor += 4 + length
        if header & 0x80 != 0 { break }
    }
    throw MediaMetadataEditError.invalidAudioMetadata
}

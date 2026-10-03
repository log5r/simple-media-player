import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

#if os(iOS)
private let importFormats = ["flac", "opus", "wav"]
#else
private let importFormats = ["flac", "ogg", "opus", "wav"]
#endif

@MainActor
struct AdditionalAudioMetadataTests {
    @Test(arguments: ["flac", "ogg", "opus", "wav"])
    func roundTripPreservesDecodedAudioAndSupportsRemoval(fileExtension: String) throws {
        let source = fixture(fileExtension)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try FileManager.default.copyItem(at: source, to: target)
        defer { try? FileManager.default.removeItem(at: target) }

        let originalSamples = try decodableSamples(at: target)
        let original = try Data(contentsOf: target)
        let artwork = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lF0AAAAASUVORK5CYII=")!
        let draft = MediaMetadataEditDraft(
            title: "Edited title", artist: "Edited artist", album: "Edited album", genre: "Jazz",
            year: "2026", trackNumber: "2/10", comment: "A comment", albumArtist: "Album artist",
            composer: "A composer", discNumber: "1/2", isCompilation: true,
            artworkData: artwork, lyrics: "First line\nSecond line", editsArtwork: true, editsLyrics: true
        )
        #expect(AdditionalAudioMetadata.canWrite(to: target))
        try AdditionalAudioMetadata.write(draft, to: target)
        let read = try AdditionalAudioMetadata.read(from: target)
        #expect(read.values.title == draft.title)
        #expect(read.values.artist == draft.artist)
        #expect(read.values.album == draft.album)
        #expect(read.values.genre == draft.genre)
        #expect(read.values.year == draft.year)
        #expect(read.values.trackNumber == draft.trackNumber)
        #expect(read.values.comment == draft.comment)
        #expect(read.values.albumArtist == draft.albumArtist)
        #expect(read.values.composer == draft.composer)
        #expect(read.values.discNumber == draft.discNumber)
        #expect(read.values.isCompilation == true)
        #expect(read.artworkData == artwork)
        #expect(read.lyrics == draft.lyrics)
        #expect(try decodableSamples(at: target) == originalSamples)
        if fileExtension != "wav" {
            #expect(try Data(contentsOf: target).range(of: Data("FOO=Keep".utf8)) != nil)
        }

        var empty = draft
        empty.title = ""
        empty.artist = ""
        empty.album = ""
        empty.genre = ""
        empty.year = ""
        empty.trackNumber = ""
        empty.comment = ""
        empty.albumArtist = ""
        empty.composer = ""
        empty.discNumber = ""
        empty.isCompilation = false
        empty.artworkData = nil
        empty.lyrics = ""
        try AdditionalAudioMetadata.write(empty, to: target)
        let cleared = try AdditionalAudioMetadata.read(from: target)
        #expect(cleared.values.title == nil)
        #expect(cleared.values.artist == nil)
        #expect(cleared.values.album == nil)
        #expect(cleared.artworkData == nil)
        #expect(cleared.lyrics == nil)
        #expect(try decodableSamples(at: target) == originalSamples)
        #expect(try Data(contentsOf: target) != original)
    }

    @Test(arguments: ["flac", "ogg", "opus", "wav"])
    func invalidSourceRemainsUnchanged(fileExtension: String) throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        defer { try? FileManager.default.removeItem(at: target) }
        let original = Data("invalid audio".utf8)
        try original.write(to: target)
        #expect(AdditionalAudioMetadata.canWrite(to: target) == false)
        #expect(throws: (any Error).self) {
            try AdditionalAudioMetadata.write(MediaMetadataEditDraft(title: "X", artist: "", album: "", genre: ""), to: target)
        }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func cancellationLeavesOriginalFLAC() async throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("flac")
        try FileManager.default.copyItem(at: fixture("flac"), to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let original = try Data(contentsOf: target)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try AdditionalAudioMetadata.write(
                MediaMetadataEditDraft(title: "Cancelled", artist: "", album: "", genre: ""), to: target
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test(arguments: ["ogg", "opus"])
    func growingCommentAcrossPagesKeepsAudioDecodable(fileExtension: String) throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try FileManager.default.copyItem(at: fixture(fileExtension), to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let originalSamples = try decodableSamples(at: target)
        let largeArtwork = Data(repeating: 0xAB, count: 80_000)
        let draft = MediaMetadataEditDraft(
            title: "Large comment", artist: "", album: "", genre: "",
            artworkData: largeArtwork, editsArtwork: true
        )

        try AdditionalAudioMetadata.write(draft, to: target)

        #expect(try AdditionalAudioMetadata.read(from: target).artworkData == largeArtwork)
        #expect(try decodableSamples(at: target) == originalSamples)
    }

    @Test(arguments: importFormats)
    func importedMetadataSurvivesASecondLibraryImport(fileExtension: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.\(fileExtension)")
        try FileManager.default.copyItem(at: fixture(fileExtension), to: source)
        let artwork = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lF0AAAAASUVORK5CYII=")!
        let draft = MediaMetadataEditDraft(
            title: "Imported title", artist: "Imported artist", album: "Imported album", genre: "Classical",
            artworkData: artwork, lyrics: "Imported lyrics", editsArtwork: true, editsLyrics: true
        )
        try AdditionalAudioMetadata.write(draft, to: source)

        let first = try library(in: directory.appendingPathComponent("First"))
        await first.service.importFiles(from: [source], into: first.context, existingItems: [])
        let item = try #require(first.context.fetch(FetchDescriptor<MediaItem>()).first)
        #expect(first.service.lastImportErrors.isEmpty)
        #expect(item.title == draft.title)
        #expect(item.artist == draft.artist)
        #expect(item.album == draft.album)
        #expect(item.genre == draft.genre)
        #expect(item.lyricsRaw == draft.lyrics)
        #expect(item.artworkData != nil)
        #expect(try await first.service.canEditEmbeddedMetadata(for: item))
        let managedURL = try #require(first.service.resolvedURL(for: item))
        #expect(try AdditionalAudioMetadata.read(from: managedURL).artworkData == artwork)
        let editable = try await first.service.editableMetadataDraft(for: item)
        #expect(editable.title == draft.title)
        #expect(editable.artworkData != nil)
        #expect(editable.lyrics == draft.lyrics)
        #expect(try await EmbeddedLyricsReader().read(from: managedURL) == draft.lyrics)

        let second = try library(in: directory.appendingPathComponent("Second"))
        await second.service.importFiles(from: [managedURL], into: second.context, existingItems: [])
        let reimported = try #require(second.context.fetch(FetchDescriptor<MediaItem>()).first)
        #expect(second.service.lastImportErrors.isEmpty)
        #expect(reimported.title == draft.title)
        #expect(reimported.artist == draft.artist)
        #expect(reimported.lyricsRaw == draft.lyrics)

        try await first.service.saveLyrics("", for: item, embedInFile: true, in: first.context)
        #expect(item.lyricsRaw == nil)
        #expect(try await EmbeddedLyricsReader().read(from: managedURL) == nil)
    }

    @Test(arguments: [TransformedExportFormat.flac, .wav])
    func transformedCopyEmbedsArtworkAndLyrics(format: TransformedExportFormat) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try FileManager.default.copyItem(at: fixture("wav"), to: source)
        let artwork = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lF0AAAAASUVORK5CYII=")!
        try AdditionalAudioMetadata.write(
            MediaMetadataEditDraft(title: "Source", artist: "Artist", album: "Album", genre: "",
                                   artworkData: artwork, lyrics: "Song lyrics", editsArtwork: true, editsLyrics: true),
            to: source
        )
        let fixture = try library(in: directory.appendingPathComponent("Managed"))
        await fixture.service.importFiles(from: [source], into: fixture.context, existingItems: [])
        let item = try #require(fixture.context.fetch(FetchDescriptor<MediaItem>()).first)
        let exporter = TransformedTrackExporter(temporaryDirectory: directory)

        let transformed = try await exporter.export(
            item: item, title: "Transformed", format: format, pitchSemitones: 0, rate: 1,
            libraryService: fixture.service, context: fixture.context
        )

        let output = try #require(fixture.service.resolvedURL(for: transformed))
        let metadata = try AdditionalAudioMetadata.read(from: output)
        #expect(metadata.values.title == "Transformed")
        #expect(metadata.values.artist == "Artist")
        #expect(metadata.values.album == "Album")
        #expect(metadata.artworkData != nil)
        #expect(metadata.lyrics == "Song lyrics")
        #expect(try AVAudioFile(forReading: output).length > 0)
    }

    @Test(arguments: ["flac", "wav"])
    func unknownMetadataAndAudioSurviveRewrite(fileExtension: String) throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        defer { try? FileManager.default.removeItem(at: target) }
        var source = try Data(contentsOf: fixture(fileExtension))
        let unknown: Data
        if fileExtension == "flac" {
            var cursor = 4
            while source[cursor] & 0x80 == 0 {
                let length = Int(source[cursor + 1]) << 16 | Int(source[cursor + 2]) << 8 | Int(source[cursor + 3])
                cursor += 4 + length
            }
            let length = Int(source[cursor + 1]) << 16 | Int(source[cursor + 2]) << 8 | Int(source[cursor + 3])
            let end = cursor + 4 + length
            source[cursor] &= 0x7f
            unknown = Data([0x82, 0, 0, 8]) + Data("TEST".utf8) + Data([1, 2, 3, 4])
            source.insert(contentsOf: unknown, at: end)
        } else {
            unknown = Data("JUNK".utf8) + Data([3, 0, 0, 0, 1, 2, 3, 0x7f])
            let size = UInt32(source.count - 8 + unknown.count)
            for index in 0..<4 { source[4 + index] = UInt8((size >> (index * 8)) & 0xff) }
            source += unknown
        }
        try source.write(to: target)
        let originalSamples = try samples(at: target)

        try AdditionalAudioMetadata.write(
            MediaMetadataEditDraft(title: "New title", artist: "", album: "", genre: ""), to: target
        )

        let written = try Data(contentsOf: target)
        #expect(written.range(of: unknown) != nil)
        #expect(try samples(at: target) == originalSamples)
    }

    @Test func corruptOggAudioPageLeavesSourceUnchanged() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("opus")
        defer { try? FileManager.default.removeItem(at: target) }
        var original = try Data(contentsOf: fixture("opus"))
        original[original.count - 10] ^= 0xff
        try original.write(to: target)
        #expect(AdditionalAudioMetadata.canWrite(to: target))

        #expect(throws: MediaMetadataEditError.invalidAudioMetadata) {
            try AdditionalAudioMetadata.write(
                MediaMetadataEditDraft(title: "Edited", artist: "", album: "", genre: ""), to: target
            )
        }

        #expect(try Data(contentsOf: target) == original)
    }

    @Test func editingFrontArtworkKeepsOtherPicturesAndCommentTrailer() throws {
        let artwork = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lF0AAAAASUVORK5CYII=")!
        var backCover = try XiphMetadata.pictureBlock(artwork)
        backCover[3] = 4
        let frontCover = try XiphMetadata.pictureBlock(Data([0xff, 0xd8, 0xff, 0xd9]))
        let backField = Data("METADATA_BLOCK_PICTURE=\(backCover.base64EncodedString())".utf8)
        let frontField = Data("METADATA_BLOCK_PICTURE=\(frontCover.base64EncodedString())".utf8)
        let comment = XiphMetadata.Comment(
            vendor: Data("Other encoder".utf8),
            fields: [backField, frontField, Data("UNKNOWN=Keep".utf8)],
            trailing: Data([0xa1, 0xb2])
        )
        let draft = MediaMetadataEditDraft(
            title: "", artist: "", album: "", genre: "", artworkData: artwork,
            editsTextMetadata: false, editsArtwork: true
        )
        let updated = try XiphMetadata.parse(XiphMetadata.encode(XiphMetadata.updating(comment, with: draft)))
        #expect(updated.vendor == comment.vendor)
        #expect(updated.trailing == comment.trailing)
        #expect(updated.fields.contains(backField))
        #expect(updated.fields.contains(frontField) == false)
        #expect(updated.fields.contains(Data("UNKNOWN=Keep".utf8)))
    }

    @Test(arguments: [("opus", "ogg"), ("opus", "oga"), ("ogg", "oga")])
    func oggCodecIsRecognizedIndependentlyOfExtension(sourceExtension: String, targetExtension: String) throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(targetExtension)
        try FileManager.default.copyItem(at: fixture(sourceExtension), to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        #expect(AdditionalAudioMetadata.canWrite(to: target))

        try AdditionalAudioMetadata.write(
            MediaMetadataEditDraft(title: "Alias title", artist: "", album: "", genre: ""), to: target
        )

        #expect(try AdditionalAudioMetadata.read(from: target).values.title == "Alias title")
    }

    private func library(in mediaDirectory: URL) throws -> (
        service: LibraryService, container: ModelContainer, context: ModelContext
    ) {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (LibraryService(mediaDirectoryURL: mediaDirectory), container, container.mainContext)
    }

    private func fixture(_ ext: String) -> URL {
        if let bundled = Bundle.allBundles.compactMap({ $0.url(forResource: "tag-test", withExtension: ext) }).first {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tag-test.\(ext)")
    }

    private func samples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
        try file.read(into: buffer)
        let channel = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func decodableSamples(at url: URL) throws -> [Float]? {
        #if os(iOS)
        // iOS 27's AVAudioFile does not decode this Ogg Vorbis fixture.
        if url.pathExtension.lowercased() == "ogg" { return nil }
        #endif
        return try samples(at: url)
    }
}

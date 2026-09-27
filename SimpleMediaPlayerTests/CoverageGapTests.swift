import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct MediaInfoDetailsTests {
    @Test func rowsAndSectionsDeriveStableIDsUnlessAnExplicitIDIsProvided() {
        let derivedRow = MediaInfoRow(label: "Codec", value: "AAC")
        let explicitRow = MediaInfoRow(id: "codec", label: "Codec", value: "AAC")
        let derivedSection = MediaInfoSection(title: "Audio", rows: [derivedRow])
        let explicitSection = MediaInfoSection(id: "audio", title: "Audio", rows: [explicitRow])

        #expect(derivedRow.id == "Codec:AAC")
        #expect(explicitRow.id == "codec")
        #expect(derivedSection.id == "Audio")
        #expect(explicitSection.id == "audio")
        #expect(
            MediaInfoDetails.empty == MediaInfoDetails(fileRows: [], summaryRows: [], sections: [], errorMessage: nil)
        )
    }

    @Test func textFormatterHandlesSizesRoundingAndNonFiniteValues() {
        #expect(MediaInfoTextFormatter.fileSize(bytes: 1_024).isEmpty == false)
        let rounded = MediaInfoTextFormatter.compactDecimal(12.345, maximumFractionDigits: 2)
        #expect(rounded.isEmpty == false)
        #expect(rounded != "12.345")
        #expect(MediaInfoTextFormatter.compactDecimal(.infinity).isEmpty)
        #expect(MediaInfoTextFormatter.compactDecimal(.nan).isEmpty)
    }

    @Test func itemSnapshotCopiesDisplayAndOptionalMetadata() {
        let item = MediaItem(
            title: "Song",
            artist: "  Artist  ",
            album: "Album",
            genre: "Genre",
            year: "2026",
            trackNumber: "2/10",
            comment: "Comment",
            albumArtist: "Album Artist",
            composer: "Composer",
            discNumber: "1/2",
            isCompilation: true,
            duration: 123,
            isVideo: false,
            bookmarkData: Data(),
            addedAt: Date(timeIntervalSince1970: 1_000),
            fileName: "song.m4a"
        )

        let snapshot = MediaInfoItemSnapshot(item: item)

        #expect(snapshot.title == "Song")
        #expect(snapshot.displayArtist == "Artist")
        #expect(snapshot.displayAlbum == "Album")
        #expect(snapshot.displayGenre == "Genre")
        #expect(snapshot.year == "2026")
        #expect(snapshot.trackNumber == "2/10")
        #expect(snapshot.comment == "Comment")
        #expect(snapshot.albumArtist == "Album Artist")
        #expect(snapshot.composer == "Composer")
        #expect(snapshot.discNumber == "1/2")
        #expect(snapshot.isCompilation)
        #expect(snapshot.duration == 123)
        #expect(snapshot.isVideo == false)
        #expect(snapshot.addedAt == Date(timeIntervalSince1970: 1_000))
        #expect(snapshot.fileName == "song.m4a")
    }
}

@MainActor
struct MediaExportPlanTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func resolvesEmbeddedAndOverrideTitlesWhileDroppingBlankMissingTitles() {
        let plan = MediaExportPlan(
            files: [
                draft(id: firstID, embeddedTitle: "Embedded", originalFileName: "one.m4a"),
                draft(id: secondID, embeddedTitle: nil, originalFileName: "two.m4a"),
                draft(id: thirdID, embeddedTitle: nil, originalFileName: "three.m4a")
            ],
            preparationErrors: ["unreadable"]
        )

        #expect(plan.missingTitleFiles.map(\.id) == [secondID, thirdID])
        let resolved = plan.resolvedFiles(nameOverrides: [
            secondID: "  Override  ",
            thirdID: " \n "
        ])

        #expect(resolved.map(\.id) == [firstID, secondID])
        #expect(resolved.map(\.title) == ["Embedded", "Override"])
        #expect(resolved[1].albumName == "Album")
        #expect(resolved[1].fileExtension == "m4a")
        #expect(resolved[1].originalFileName == "two.m4a")
        #expect(plan.preparationErrors == ["unreadable"])
    }

    @Test func draftDisplayNameFallsBackToItsIdentifier() {
        let draft = draft(id: firstID, embeddedTitle: nil, originalFileName: "")

        #expect(draft.displayName == firstID.uuidString)
    }

    @Test func sanitizerCollapsesUnsafeCharactersAndRejectsDotPaths() {
        #expect(MediaExportNaming.sanitizedPathComponent("  A/B:\nC  ", fallback: "Fallback") == "A B C")
        #expect(MediaExportNaming.sanitizedPathComponent("..", fallback: "Fallback") == "Fallback")
        #expect(MediaExportNaming.sanitizedPathComponent(" \n ", fallback: "Fallback") == "Fallback")
    }

    @Test func timestampNameAddsZeroPaddedIndex() {
        let value = MediaExportNaming.timestampName(date: Date(timeIntervalSince1970: 0), index: 7)

        #expect(value.hasSuffix("_007"))
        #expect(value.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_007$"#, options: .regularExpression) != nil)
    }

    private func draft(id: UUID, embeddedTitle: String?, originalFileName: String) -> MediaExportFileDraft {
        MediaExportFileDraft(
            id: id,
            sourceURL: URL(fileURLWithPath: "/tmp/\(originalFileName)"),
            albumName: "Album",
            embeddedTitle: embeddedTitle,
            fileExtension: "m4a",
            originalFileName: originalFileName
        )
    }
}

struct TransformedExportFormatTests {
    @Test func formatsExposeExpectedExtensionsAndCapabilities() {
        #expect(TransformedExportFormat.allCases.map(\.fileExtension) == ["mp3", "m4a", "m4a", "flac", "wav", "aiff"])
        #expect(TransformedExportFormat.allCases.map(\.isLossless) == [false, false, true, true, true, true])
        #expect(TransformedExportFormat.allCases.map(\.supportsEmbeddedTags) == [true, true, true, true, true, true])
        #expect(TransformedExportFormat.mp3.maxSampleRate == 48_000)
        #expect(TransformedExportFormat.aac.maxSampleRate == nil)
        #expect(TransformedExportFormat.allCases.allSatisfy { $0.displayName.isEmpty == false })
        #expect(TransformedExportFormat.allCases.filter { $0 != .mp3 }.allSatisfy { $0.isAvailable })
    }

    @Test func audioFileSettingsDescribeCompressedLosslessAndPCMOutputs() throws {
        #expect(TransformedExportFormat.mp3.avAudioFileSettings(sampleRate: 44_100, channels: 2) == nil)

        let aac = try #require(TransformedExportFormat.aac.avAudioFileSettings(sampleRate: 44_100, channels: 2))
        #expect(aac[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        #expect(aac[AVSampleRateKey] as? Double == 44_100)
        #expect(aac[AVNumberOfChannelsKey] as? UInt32 == 2)
        #expect(aac[AVEncoderBitRateKey] as? Int == 256_000)

        let lossless = try #require(
            TransformedExportFormat.appleLossless.avAudioFileSettings(sampleRate: 48_000, channels: 1)
        )
        #expect(lossless[AVFormatIDKey] as? UInt32 == kAudioFormatAppleLossless)

        let flac = try #require(TransformedExportFormat.flac.avAudioFileSettings(sampleRate: 48_000, channels: 2))
        #expect(flac[AVFormatIDKey] as? UInt32 == kAudioFormatFLAC)

        let wav = try #require(TransformedExportFormat.wav.avAudioFileSettings(sampleRate: 96_000, channels: 2))
        let aiff = try #require(TransformedExportFormat.aiff.avAudioFileSettings(sampleRate: 96_000, channels: 2))
        #expect(wav[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
        #expect(wav[AVLinearPCMIsBigEndianKey] as? Bool == false)
        #expect(aiff[AVLinearPCMIsBigEndianKey] as? Bool == true)
        #expect(aiff[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    @Test func metadataWriterDoesNotCreateMissingOutput() throws {
        let missingBase = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        let draft = MediaMetadataEditDraft(
            title: "Title",
            artist: "Artist",
            album: "Album",
            genre: "Genre",
            year: "",
            trackNumber: "",
            comment: "",
            artworkData: nil
        )

        for format in [TransformedExportFormat.flac, .wav] {
            let missingURL = missingBase.appendingPathExtension(format.fileExtension)
            #expect(throws: (any Error).self) { try format.writeMetadata(draft, to: missingURL) }
            #expect(FileManager.default.fileExists(atPath: missingURL.path) == false)
        }
    }

    @Test func exportErrorsPreserveSpecificMessages() {
        #expect(TransformedAudioExportError.cannotResolveFile.errorDescription?.isEmpty == false)
        #expect(TransformedAudioExportError.invalidRenderFormat.errorDescription?.isEmpty == false)
        #expect(TransformedAudioExportError.encoderUnavailable("encoder").errorDescription == "encoder")
        #expect(TransformedAudioExportError.renderFailed("render").errorDescription == "render")
        #expect(TransformedAudioExportError.emptyTitle.errorDescription?.isEmpty == false)
    }
}

struct AudioRenderingTests {
    @Test func coreAudioEncoderWritesPCMAndRejectsMP3Settings() throws {
        let outputURL = temporaryAudioURL(extension: "wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try makeAudioBuffer(format: format, frameCount: 512)

        var encoder: CoreAudioFileEncoder? = try CoreAudioFileEncoder(
            outputURL: outputURL,
            format: .wav,
            processingFormat: format
        )
        try encoder?.encode(buffer: buffer)
        try encoder?.finish()
        encoder = nil

        let writtenFile = try AVAudioFile(forReading: outputURL)
        #expect(writtenFile.length == 512)

        #expect(throws: TransformedAudioExportError.self) {
            _ = try CoreAudioFileEncoder(outputURL: outputURL, format: .mp3, processingFormat: format)
        }
    }

    @Test func rendererEmitsAudioProgressAndFinishesItsEncoder() throws {
        let sourceURL = temporaryAudioURL(extension: "caf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let sourceBuffer = try makeAudioBuffer(format: sourceFormat, frameCount: 4_410)
        do {
            let file = try AVAudioFile(forWriting: sourceURL, settings: sourceFormat.settings)
            try file.write(from: sourceBuffer)
        }

        let encoder = RecordingAudioEncoder()
        var encoderFormat: AVAudioFormat?
        let progress = ProgressRecorder()
        let result = try TransformedAudioRenderer().render(
            sourceURL: sourceURL,
            pitchCents: 0,
            rate: 1,
            maxSampleRate: nil,
            makeEncoder: { format in
                encoderFormat = format
                return encoder
            },
            progress: { value in
                progress.append(value)
            }
        )
        let progressValues = progress.values

        #expect(encoderFormat?.sampleRate == 44_100)
        #expect(encoderFormat?.channelCount == 1)
        #expect(encoder.encodedFrameCount > 0)
        #expect(encoder.finishCallCount == 1)
        #expect(result.duration > 0)
        #expect(progressValues.last == 1)
        #expect(progressValues.allSatisfy { (0...1).contains($0) })
    }
}

private final class RecordingAudioEncoder: AudioFileEncoding, @unchecked Sendable {
    private(set) var encodedFrameCount: AVAudioFrameCount = 0
    private(set) var finishCallCount = 0

    func encode(buffer: AVAudioPCMBuffer) throws {
        encodedFrameCount += buffer.frameLength
    }

    func finish() throws {
        finishCallCount += 1
    }

    func cancel() {}
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        lock.withLock { storedValues }
    }

    func append(_ value: Double) {
        lock.withLock { storedValues.append(value) }
    }
}

private func temporaryAudioURL(extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("coverage-\(UUID().uuidString)")
        .appendingPathExtension(pathExtension)
}

private func makeAudioBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let channelData = try #require(buffer.floatChannelData)
    for channel in 0..<Int(format.channelCount) {
        for frame in 0..<Int(frameCount) {
            channelData[channel][frame] = sin(Float(frame) * 0.05) * 0.1
        }
    }
    return buffer
}

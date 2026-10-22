import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct AudioFileEncodingTests {
    @Test func coreAudioRejectsMP3BeforeCreatingAFile() throws {
        let url = temporaryURL(extension: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        #expect(throws: TransformedAudioExportError.self) {
            _ = try CoreAudioFileEncoder(outputURL: url, format: .mp3, processingFormat: format)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func mp3EncoderReportsLaunchAndExitFailures(missingExecutable: Bool) throws {
        let url = temporaryURL(extension: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let encoder = try MP3Encoder(
            outputURL: url, processingFormat: format,
            executableURL: URL(fileURLWithPath: missingExecutable ? "/missing/lame" : "/bin/sh"),
            arguments: ["-c", "exit 17"]
        )
        defer { encoder.cancel() }
        if missingExecutable {
            #expect(throws: (any Error).self) { try encoder.finish() }
        } else {
            do {
                try encoder.finish()
                Issue.record("A nonzero encoder exit must fail the export.")
            } catch let TransformedAudioExportError.encoderUnavailable(message) {
                #expect(message.contains("17"))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    #else
    @Test func mp3EncodingIsUnavailableAndFailsExplicitly() throws {
        let url = temporaryURL(extension: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let encoder = try MP3Encoder(outputURL: url, processingFormat: format)
        defer { encoder.cancel() }
        #expect(!MP3Encoder.isAvailable)
        #expect(throws: TransformedAudioExportError.self) { try encoder.finish() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    #endif

    private func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
    }
}

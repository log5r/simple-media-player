import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

#if os(macOS)
import Darwin
#endif

struct AudioEncodingCancellationTests {
    @Test func cancellationBeforeRenderingDoesNotOpenSourceOrCreateEncoder() async throws {
        let encoder = CancellationRecordingEncoder()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try TransformedAudioRenderer().render(
                sourceURL: URL(fileURLWithPath: "/missing-cancelled-export.caf"),
                pitchCents: 0,
                rate: 1,
                maxSampleRate: nil,
                makeEncoder: { _ in
                    encoder.wasCreated = true
                    return encoder
                },
                progress: { _ in }
            )
        }

        let result = await task.result
        #expect(isCancellation(result))
        #expect(encoder.wasCreated == false)
    }

    @Test(arguments: [CancellationRecordingEncoder.Behavior.failEncoding, .cancelDuringEncoding, .cancelDuringFinish])
    private func rendererAbortsEncoderInsteadOfFinishingAfterFailure(
        behavior: CancellationRecordingEncoder.Behavior
    ) async throws {
        let sourceURL = temporaryURL(extension: "caf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try writeSource(to: sourceURL)
        let encoder = CancellationRecordingEncoder(behavior: behavior)
        let task = Task.detached {
            try TransformedAudioRenderer().render(
                sourceURL: sourceURL,
                pitchCents: 0,
                rate: 1,
                maxSampleRate: nil,
                makeEncoder: { _ in encoder },
                progress: { _ in }
            )
        }

        let result = await task.result
        switch behavior {
        case .failEncoding:
            if case .failure(let error) = result {
                #expect(error is CancellationRecordingEncoder.EncodingFailure)
            } else {
                Issue.record("Rendering unexpectedly succeeded after the encoder failed.")
            }
        case .cancelDuringEncoding, .cancelDuringFinish:
            #expect(isCancellation(result))
        }
        #expect(encoder.cancelCallCount == 1)
        #expect(encoder.finishCallCount == (behavior == .cancelDuringFinish ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func closingCoreAudioEncoderClosesFileWhileEncoderRemainsAlive(cancel: Bool) throws {
        let outputURL = temporaryURL(extension: "wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let encoder = try CoreAudioFileEncoder(outputURL: outputURL, format: .wav, processingFormat: format)
        let buffer = try makeBuffer(format: format)
        try encoder.encode(buffer: buffer)
        if cancel {
            encoder.cancel()
        } else {
            try encoder.finish()
        }

        let file = try AVAudioFile(forReading: outputURL)
        #expect(file.length == AVAudioFramePosition(buffer.frameLength))
        #expect(throws: CocoaError.self) { try encoder.encode(buffer: buffer) }
    }

    #if os(macOS)
    @Test func cancelledMP3FinishDoesNotLaunchEncoder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = try makeEncoderScript(in: directory, ignoresTermination: false)
        let outputURL = directory.appendingPathComponent("output.mp3")
        let task = Task.detached {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let encoder = try MP3Encoder(
                outputURL: outputURL,
                processingFormat: format,
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [scriptURL.path]
            )
            defer { encoder.cancel() }
            withUnsafeCurrentTask { $0?.cancel() }
            try encoder.finish()
        }

        let result = await task.result
        #expect(isCancellation(result))
        #expect(FileManager.default.fileExists(atPath: scriptURL.appendingPathExtension("pid").path) == false)
    }

    @Test func cancellingRunningMP3EncoderTerminatesAndReapsProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = try makeEncoderScript(in: directory, ignoresTermination: true)
        let outputURL = directory.appendingPathComponent("output.mp3")
        let pidURL = scriptURL.appendingPathExtension("pid")
        let task = Task.detached {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let encoder = try MP3Encoder(
                outputURL: outputURL,
                processingFormat: format,
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [scriptURL.path]
            )
            defer { encoder.cancel() }
            try encoder.finish()
        }
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while FileManager.default.fileExists(atPath: pidURL.path) == false && ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancellationTime = ContinuousClock.now
        task.cancel()
        let result = await task.result
        let elapsed = cancellationTime.duration(to: .now)

        #expect(isCancellation(result))
        #expect(elapsed < .seconds(3))
        let processID = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        let signalResult = kill(processID, 0)
        let signalError = errno
        #expect(signalResult == -1)
        #expect(signalError == ESRCH)
    }

    private func makeEncoderScript(in directory: URL, ignoresTermination: Bool) throws -> URL {
        let scriptURL = directory.appendingPathComponent("encoder.sh")
        let script = """
        #!/bin/sh
        \(ignoresTermination ? "trap '' TERM" : "")
        printf '%s' "$$" > "$0.pid"
        \(ignoresTermination
            ? "deadline=$((SECONDS + 10)); while [ \"$SECONDS\" -lt \"$deadline\" ]; do :; done"
            : "exit 0")
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        return scriptURL
    }
    #endif

    private func writeSource(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: makeBuffer(format: format))
    }

    private func makeBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let samples = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            samples[0][frame] = sin(Float(frame) * 0.05) * 0.1
        }
        return buffer
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
    }

    private func isCancellation<Value>(_ result: Result<Value, Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }
}

private final class CancellationRecordingEncoder: AudioFileEncoding, @unchecked Sendable {
    enum Behavior: Sendable {
        case failEncoding
        case cancelDuringEncoding
        case cancelDuringFinish
    }

    struct EncodingFailure: Error {}

    let behavior: Behavior
    var wasCreated = false
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0

    init(behavior: Behavior = .failEncoding) {
        self.behavior = behavior
    }

    func encode(buffer: AVAudioPCMBuffer) throws {
        switch behavior {
        case .failEncoding:
            throw EncodingFailure()
        case .cancelDuringEncoding:
            withUnsafeCurrentTask { $0?.cancel() }
        case .cancelDuringFinish:
            break
        }
    }

    func finish() throws {
        finishCallCount += 1
        if behavior == .cancelDuringFinish {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func cancel() {
        cancelCallCount += 1
    }
}

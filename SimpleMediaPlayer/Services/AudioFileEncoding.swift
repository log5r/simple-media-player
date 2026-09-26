import AVFoundation
import Foundation
#if os(macOS)
import Darwin
#endif

// The render worker calls these methods serially, including cancellation cleanup.
nonisolated protocol AudioFileEncoding: AnyObject, Sendable {
    func encode(buffer: AVAudioPCMBuffer) throws
    func finish() throws
    func cancel()
}

nonisolated final class CoreAudioFileEncoder: AudioFileEncoding, @unchecked Sendable {
    private var file: AVAudioFile?

    init(outputURL: URL, format: TransformedExportFormat, processingFormat: AVAudioFormat) throws {
        guard let settings = format.avAudioFileSettings(
            sampleRate: processingFormat.sampleRate,
            channels: processingFormat.channelCount
        ) else {
            throw TransformedAudioExportError.encoderUnavailable(L10n.string("This format is not available."))
        }
        file = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func encode(buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw CocoaError(.fileWriteUnknown) }
        try file.write(from: buffer)
    }

    func finish() throws {
        file = nil
    }

    func cancel() {
        file = nil
    }
}

nonisolated final class MP3Encoder: AudioFileEncoding, @unchecked Sendable {
    private static let bitrateKbps = 256
    private let outputURL: URL
    private let wavURL: URL
    private let wavEncoder: CoreAudioFileEncoder
    #if os(macOS)
    private var executableURL: URL?
    private var processArguments: [String]?
    #endif

    static var isAvailable: Bool {
        #if os(macOS)
        lameExecutableURL != nil
        #else
        false
        #endif
    }

    init(outputURL: URL, processingFormat: AVAudioFormat) throws {
        self.outputURL = outputURL
        wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        wavEncoder = try CoreAudioFileEncoder(outputURL: wavURL, format: .wav, processingFormat: processingFormat)
    }

    #if os(macOS)
    convenience init(
        outputURL: URL,
        processingFormat: AVAudioFormat,
        executableURL: URL,
        arguments: [String]? = nil
    ) throws {
        try self.init(outputURL: outputURL, processingFormat: processingFormat)
        self.executableURL = executableURL
        self.processArguments = arguments
    }
    #endif

    deinit {
        wavEncoder.cancel()
        try? FileManager.default.removeItem(at: wavURL)
    }

    func encode(buffer: AVAudioPCMBuffer) throws {
        try wavEncoder.encode(buffer: buffer)
    }

    func finish() throws {
        try Task.checkCancellation()
        try wavEncoder.finish()
        #if os(macOS)
        guard let lameURL = executableURL ?? Self.lameExecutableURL else {
            throw TransformedAudioExportError.encoderUnavailable(
                L10n.string("MP3 export requires the LAME encoder. Install lame or choose another format.")
            )
        }
        let process = Process()
        process.executableURL = lameURL
        process.arguments = processArguments ?? [
            "--quiet",
            "-b", "\(Self.bitrateKbps)",
            "-q", "2",
            wavURL.path,
            outputURL.path
        ]
        try Task.checkCancellation()
        try process.run()
        defer {
            if process.isRunning {
                Self.stop(process)
            }
        }
        while process.isRunning {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw TransformedAudioExportError.encoderUnavailable(
                L10n.format("MP3 encoder failed with status %d.", Int(process.terminationStatus))
            )
        }
        #else
        throw TransformedAudioExportError.encoderUnavailable(
            L10n.string("MP3 export requires LAME and is not available on this platform.")
        )
        #endif
    }

    func cancel() {
        wavEncoder.cancel()
        try? FileManager.default.removeItem(at: wavURL)
    }

    #if os(macOS)
    private static func stop(_ process: Process) {
        process.terminate()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while process.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        // An encoder that ignores SIGTERM must not keep export cleanup waiting.
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static var lameExecutableURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/lame",
            "/usr/local/bin/lame",
            "/usr/bin/lame"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
    #endif
}

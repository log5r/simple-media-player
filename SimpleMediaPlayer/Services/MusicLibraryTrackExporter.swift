import AVFoundation
import CoreMedia
import Foundation

/// Writes the audio of a Music library asset as a regular file. `assetURL` values from the Music
/// library are not file URLs, so they are never copied or imported directly.
///
/// The original encoding is kept whenever AVFoundation can pass it through: MP3 frames are copied
/// into a bare MPEG stream, AAC and Apple Lossless go into M4A, and PCM goes into AIFF or WAV. Any other
/// encoding is converted to AAC and reported as transcoded.
nonisolated enum MusicLibraryTrackExporter {
    enum OutputFormat: String, Sendable {
        case mp3
        case m4a
        case aiff
        case wav
        case caf
    }

    struct Output: Sendable, Equatable {
        let url: URL
        let format: OutputFormat
        let isTranscoded: Bool
        let duration: TimeInterval
    }

    private enum Strategy {
        case copyMPEGFrames
        case passthrough(AVFileType, OutputFormat)
        case transcode
    }

    static func export(assetURL: URL, to directory: URL, baseName: String) async throws -> Output {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: assetURL)
        let (isReadable, hasProtectedContent, isExportable) = try await asset.load(
            .isReadable, .hasProtectedContent, .isExportable
        )
        guard hasProtectedContent == false else { throw MusicLibraryTrackError.protectedAsset }
        guard isReadable else { throw MusicLibraryTrackError.notReadable }
        guard isExportable else { throw MusicLibraryTrackError.notExportable }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MusicLibraryTrackError.noAudioTrack
        }
        let formatID = try await sourceFormatID(of: track)
        let strategy = await strategy(for: asset, formatID: formatID, sourceExtension: assetURL.pathExtension)
        try Task.checkCancellation()

        let (format, isTranscoded) = outputFormat(for: strategy)
        let outputURL = directory.appendingPathComponent(baseName).appendingPathExtension(format.rawValue)
        try? FileManager.default.removeItem(at: outputURL)
        do {
            switch strategy {
            case .copyMPEGFrames:
                try await copyMPEGFrames(assetURL: assetURL, to: outputURL)
            case let .passthrough(fileType, _):
                try await runExportSession(
                    assetURL: assetURL, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: outputURL
                )
            case .transcode:
                try await runExportSession(
                    assetURL: assetURL, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: outputURL
                )
            }
            let duration = try await validateOutput(at: outputURL)
            return Output(url: outputURL, format: format, isTranscoded: isTranscoded, duration: duration)
        } catch {
            // An abandoned validation may still be opening the file. Unlinking it is safe: the open handle
            // keeps reading the unlinked file on APFS and its result is discarded.
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func sourceFormatID(of track: AVAssetTrack) async throws -> AudioFormatID? {
        let descriptions = try await track.load(.formatDescriptions)
        return descriptions.lazy
            .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mFormatID }
            .first
    }

    private static func strategy(
        for asset: AVURLAsset, formatID: AudioFormatID?, sourceExtension: String
    ) async -> Strategy {
        if formatID == kAudioFormatMPEGLayer3 { return .copyMPEGFrames }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return .transcode
        }
        // `supportedFileTypes` lists containers the preset can write for any asset; only
        // `compatibleFileTypes` reflects this asset's encoding.
        let compatible = Set(await session.compatibleFileTypes)
        let preferred: [(AVFileType, OutputFormat)]
        if formatID == kAudioFormatLinearPCM {
            let prefersAIFF = ["aif", "aiff", "aifc"].contains(sourceExtension.lowercased())
            preferred = prefersAIFF
                ? [(.aiff, .aiff), (.wav, .wav), (.caf, .caf)]
                : [(.wav, .wav), (.aiff, .aiff), (.caf, .caf)]
        } else {
            preferred = [(.m4a, .m4a), (.caf, .caf)]
        }
        if let match = preferred.first(where: { compatible.contains($0.0) }) {
            return .passthrough(match.0, match.1)
        }
        return .transcode
    }

    private static func outputFormat(for strategy: Strategy) -> (OutputFormat, Bool) {
        switch strategy {
        case .copyMPEGFrames: (.mp3, false)
        case let .passthrough(_, format): (format, false)
        case .transcode: (.m4a, true)
        }
    }

    private static func runExportSession(
        assetURL: URL, preset: String, fileType: AVFileType, to outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: assetURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MusicLibraryTrackError.notExportable
        }
        // `cancelExport()` may be called from any thread; the session is used by no other task.
        nonisolated(unsafe) let cancellableSession = session
        do {
            try await withTaskCancellationHandler {
                try await session.export(to: outputURL, as: fileType)
            } onCancel: {
                cancellableSession.cancelExport()
            }
        } catch {
            try Task.checkCancellation()
            throw MusicLibraryTrackError.exportFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
    }

    /// MP3 packets are self-framed, so writing them in order produces a playable stream without the
    /// container the reader took them from. Runs off the caller's actor because the reader blocks.
    private static func copyMPEGFrames(assetURL: URL, to outputURL: URL) async throws {
        let copy = Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: assetURL)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw MusicLibraryTrackError.noAudioTrack
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MusicLibraryTrackError.notReadable }
            reader.add(output)
            guard reader.startReading() else {
                throw MusicLibraryTrackError.exportFailed(reader.error?.localizedDescription ?? "")
            }
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            while let sampleBuffer = output.copyNextSampleBuffer() {
                if Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }
                try handle.write(contentsOf: packetData(of: sampleBuffer))
            }
            switch reader.status {
            case .completed:
                return
            case .cancelled:
                throw CancellationError()
            default:
                throw MusicLibraryTrackError.exportFailed(reader.error?.localizedDescription ?? "")
            }
        }
        try await withTaskCancellationHandler {
            try await copy.value
        } onCancel: {
            copy.cancel()
        }
    }

    private static func packetData(of sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return Data() }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            guard let destination = buffer.baseAddress else { return }
            let status = CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length, destination: destination
            )
            guard status == kCMBlockBufferNoErr else {
                throw MusicLibraryTrackError.exportFailed("CMBlockBuffer \(status)")
            }
        }
        return data
    }

    /// The file must decode through the same path the player uses before it is played or imported.
    /// The open cannot be interrupted, so a cancelled caller stops waiting and the queued open finishes
    /// on its own with its result discarded.
    private static func validateOutput(at url: URL) async throws -> TimeInterval {
        let result = try await FileSystemWorkQueue.runCancellable(qos: .userInitiated) {
            Result { () throws -> TimeInterval in
                let file = try AVAudioFile(forReading: url)
                let sampleRate = file.fileFormat.sampleRate
                guard file.length > 0, sampleRate > 0 else { throw MusicLibraryTrackError.outputNotDecodable }
                return TimeInterval(file.length) / sampleRate
            }
        }
        // The work may finish just as the caller is cancelled; a cancelled request reports no result.
        try Task.checkCancellation()
        return try result.get()
    }
}

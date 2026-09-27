import AVFoundation
import AudioToolbox
import Foundation

nonisolated enum TransformedExportFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3
    case aac
    case appleLossless
    case flac
    case wav
    case aiff

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .mp3:
            "mp3"
        case .aac, .appleLossless:
            "m4a"
        case .flac:
            "flac"
        case .wav:
            "wav"
        case .aiff:
            "aiff"
        }
    }

    var displayName: String {
        switch self {
        case .mp3:
            L10n.string("MP3 (256 kbps)")
        case .aac:
            L10n.string("AAC (256 kbps)")
        case .appleLossless:
            L10n.string("Apple Lossless")
        case .flac:
            L10n.string("FLAC")
        case .wav:
            L10n.string("WAV")
        case .aiff:
            L10n.string("AIFF")
        }
    }

    var isLossless: Bool {
        switch self {
        case .mp3, .aac:
            false
        case .appleLossless, .flac, .wav, .aiff:
            true
        }
    }

    var supportsEmbeddedTags: Bool {
        switch self {
        case .mp3, .aac, .appleLossless, .aiff, .flac, .wav:
            true
        }
    }

    var isAvailable: Bool {
        switch self {
        case .mp3:
            MP3Encoder.isAvailable
        case .aac, .appleLossless, .flac, .wav, .aiff:
            true
        }
    }

    var maxSampleRate: Double? {
        self == .mp3 ? 48_000 : nil
    }

    func avAudioFileSettings(sampleRate: Double, channels: UInt32) -> [String: Any]? {
        switch self {
        case .mp3:
            nil
        case .aac:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 256_000
            ]
        case .appleLossless:
            [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels
            ]
        case .flac:
            [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels
            ]
        case .wav, .aiff:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: self == .aiff,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    func writeMetadata(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        switch self {
        case .mp3:
            try ID3TagWriter.write(draft, to: url)
        case .aac, .appleLossless:
            try MP4MetadataWriter.write(draft, to: url)
        case .aiff:
            try AIFFMetadataWriter.write(draft, to: url)
        case .flac, .wav:
            try AdditionalAudioMetadata.write(draft, to: url)
        }
    }
}

nonisolated enum TransformedAudioExportError: LocalizedError {
    case cannotResolveFile
    case invalidRenderFormat
    case encoderUnavailable(String)
    case renderFailed(String)
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .cannotResolveFile:
            L10n.string("Could not resolve the media file.")
        case .invalidRenderFormat:
            L10n.string("Could not create an audio render format.")
        case let .encoderUnavailable(message):
            message
        case let .renderFailed(message):
            message
        case .emptyTitle:
            L10n.string("Enter a title.")
        }
    }
}

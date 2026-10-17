import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct PitchProcessingSource {
    let url: URL

    init(sampleRate: Double, channelCount: AVAudioChannelCount, samples: [Float]) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitch-processing-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channelCount) {
            let channelGain: Float = channel == 0 ? 1 : -0.9
            for (frame, sample) in samples.enumerated() {
                channels[channel][frame] = sample * channelGain
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    static func harmonics(sampleRate: Double) -> [Float] {
        let duration = 1.0
        let samples = (0..<Int(duration * sampleRate)).map { frame in
            let time = Double(frame) / sampleRate
            var sample = 0.0
            for harmonic in 1...60 {
                sample += sin(2 * .pi * 110 * Double(harmonic) * time) / Double(harmonic)
            }
            return Float(sample * min(1, time / 0.03, (duration - time) / 0.03))
        }
        let peak = samples.map { abs($0) }.max() ?? 1
        return samples.map { $0 * 0.95 / peak }
    }
}

// Rendering calls the encoder serially. Tests inspect it only after the synchronous
// render returns or its detached task completes, so no storage is accessed concurrently.
nonisolated final class PitchProcessingEncoder: AudioFileEncoding, @unchecked Sendable {
    enum Behavior: Sendable {
        case record
        case failEncoding
        case cancelDuringEncoding
    }

    struct EncodingFailure: Error {}

    private let behavior: Behavior
    private(set) var sampleRate = 0.0
    private(set) var channels: [[Float]] = []
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    var frameCount: Int { channels.first?.count ?? 0 }

    init(behavior: Behavior = .record) {
        self.behavior = behavior
    }

    func encode(buffer: AVAudioPCMBuffer) throws {
        switch behavior {
        case .failEncoding:
            throw EncodingFailure()
        case .cancelDuringEncoding:
            withUnsafeCurrentTask { $0?.cancel() }
        case .record:
            break
        }
        sampleRate = buffer.format.sampleRate
        if channels.isEmpty {
            channels = Array(repeating: [], count: Int(buffer.format.channelCount))
        }
        let data = try #require(buffer.floatChannelData)
        for channel in channels.indices {
            channels[channel].append(contentsOf: UnsafeBufferPointer(
                start: data[channel],
                count: Int(buffer.frameLength)
            ))
        }
    }

    func finish() throws {
        finishCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }
}

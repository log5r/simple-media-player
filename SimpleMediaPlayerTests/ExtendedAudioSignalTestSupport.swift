import AVFoundation
import Foundation
import SFBAudioEngine
import Testing
@testable import SimpleMediaPlayer

nonisolated struct ExtendedAudioSignalFixture {
    static let sampleRate = 44_100.0
    static let frameCount = 44_137
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("decode-signal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func source(extension fileExtension: String) throws -> URL {
        let source = directory.appendingPathComponent("source.\(fileExtension)")
        if fileExtension == "wma" {
            try FileManager.default.copyItem(at: Self.bundled("known-stereo", extension: "wma"), to: source)
        } else if fileExtension == "ape" {
            try FileManager.default.copyItem(at: Self.bundled("extended-test", extension: "ape"), to: source)
        } else if fileExtension == "mpc" {
            try FileManager.default.copyItem(at: Self.bundled("known-stereo", extension: "mpc"), to: source)
        } else {
            let reference = directory.appendingPathComponent("reference.wav")
            try writeReference(to: reference)
            try AudioConverter.convert(reference, to: source)
        }
        return source
    }

    static func bundled(_ name: String, extension fileExtension: String) -> URL {
        Bundle.allBundles.compactMap { $0.url(forResource: name, withExtension: fileExtension) }.first
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name).\(fileExtension)")
    }

    static func independentReference(for fileExtension: String) -> URL? {
        switch fileExtension {
        case "ape": bundled("extended-test-ape-reference", extension: "wav")
        case "wma": bundled("known-stereo-wma-reference", extension: "wav")
        default: nil
        }
    }

    static func expectedSample(frame: Int, channel: Int) -> Float {
        if frame == 0 { return channel == 0 ? 0.25 : -0.125 }
        if frame == frameCount - 1 { return channel == 0 ? -0.375 : 0.3125 }
        let frequency: Double
        if frame < frameCount * 3 / 4 {
            frequency = channel == 0 ? 440 : 880
        } else {
            frequency = channel == 0 ? 1_760 : 2_200
        }
        let integer = (sin(2 * .pi * frequency * Double(frame) / sampleRate) * 10_000).rounded()
        return Float(integer / 32_768)
    }

    static func readPCM(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        try #require(file.processingFormat.sampleRate == sampleRate)
        try #require(file.processingFormat.channelCount == 2)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        try #require(AVAudioFramePosition(buffer.frameLength) == file.length)
        let channels = try #require(buffer.floatChannelData)
        return (0..<2).map { Array(UnsafeBufferPointer(start: channels[$0], count: Int(buffer.frameLength))) }
    }

    private func writeReference(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.frameCount)
        ))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<Self.frameCount {
                samples[channel][frame] = Self.expectedSample(frame: frame, channel: channel)
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
    }
}

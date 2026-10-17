import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import SimpleMediaPlayer

// The test drives the render block synchronously. Its pull-input closure and all
// mutable storage are confined to that same call, just as on an audio render thread.
nonisolated final class PitchEffectRenderFixture: @unchecked Sendable {
    let effect = SMPPitchEffect()
    let sampleRate: Double
    let channelCount: Int
    private let unit: AUAudioUnit
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var source: [Float] = []
    private var sourcePosition = 0
    private var inputIsSilent = false
    private var resetDuringNextPull = false
    private(set) var audibleOutputMarkedSilent = false
    private(set) var audibleOutputAfterSilentInput = false

    var latencyFrames: Int { Int((effect.latency * sampleRate).rounded()) }

    init(sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2, pitchCents: Float = -300) throws {
        self.sampleRate = sampleRate
        channelCount = Int(channels)
        if #available(macOS 27, iOS 27, *) {
            unit = effect.node.withAUAudioUnit { $0 }
        } else {
            unit = effect.node.auAudioUnit
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 4096
        effect.pitchCents = pitchCents
        try unit.allocateRenderResources()
    }

    deinit {
        unit.deallocateRenderResources()
    }

    func render(_ samples: [Float], chunks: [Int] = [512], trimLatency: Bool = true) throws -> [[Float]] {
        source = samples
        sourcePosition = 0
        audibleOutputMarkedSilent = false
        audibleOutputAfterSilentInput = false
        let totalFrames = samples.count + latencyFrames
        var result = Array(repeating: [Float](), count: channelCount)
        var step = 0
        while sourcePosition < totalFrames {
            let count = min(chunks[step % chunks.count], totalFrames - sourcePosition)
            let rendered = try renderChunk(count)
            for channel in result.indices { result[channel].append(contentsOf: rendered[channel]) }
            step += 1
        }
        return trimLatency ? result.map { Array($0.dropFirst(latencyFrames)) } : result
    }

    func renderWithResetDuringInputPull(_ samples: [Float]) throws -> [[Float]] {
        try #require(samples.isEmpty == false && samples.count <= Int(input.frameCapacity))
        source = samples
        sourcePosition = 0
        resetDuringNextPull = true
        defer { resetDuringNextPull = false }
        return try renderChunk(samples.count)
    }

    private func renderChunk(_ count: Int) throws -> [[Float]] {
        input.frameLength = AVAudioFrameCount(count)
        output.frameLength = AVAudioFrameCount(count)
        let inputChannels = try #require(input.floatChannelData)
        inputIsSilent = sourcePosition >= source.count
        for channel in 0..<channelCount {
            let gain: Float = channel == 0 ? 1 : -0.8
            for frame in 0..<count {
                let index = sourcePosition + frame
                inputChannels[channel][frame] = index < source.count ? source[index] * gain : 0
            }
        }
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = Double(sourcePosition)
        timestamp.mFlags = .sampleTimeValid
        var flags: AudioUnitRenderActionFlags = []
        let status = unit.renderBlock(
            &flags, &timestamp, AVAudioFrameCount(count), 0, output.mutableAudioBufferList
        ) { [self] flags, _, frameCount, _, buffers in
            provideInput(flags: flags, frameCount: frameCount, buffers: buffers)
        }
        try #require(status == noErr)
        let outputChannels = try #require(output.floatChannelData)
        let rendered = (0..<channelCount).map { channel in
            Array(UnsafeBufferPointer(start: outputChannels[channel], count: count))
        }
        let audible = rendered.contains { $0.contains { abs($0) > 0.000_01 } }
        if audible && inputIsSilent { audibleOutputAfterSilentInput = true }
        if audible && flags.contains(.unitRenderAction_OutputIsSilence) { audibleOutputMarkedSilent = true }
        sourcePosition += count
        return rendered
    }

    private func provideInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        frameCount: AUAudioFrameCount,
        buffers: UnsafeMutablePointer<AudioBufferList>
    ) -> AUAudioUnitStatus {
        let destination = UnsafeMutableAudioBufferListPointer(buffers)
        let original = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        guard destination.count == channelCount, frameCount == input.frameLength else {
            return kAudioUnitErr_FormatNotSupported
        }
        for channel in 0..<channelCount {
            destination[channel] = original[channel]
            // AudioUnits may receive silence with no backing samples after EOF.
            if inputIsSilent { destination[channel].mData = nil }
        }
        if resetDuringNextPull {
            resetDuringNextPull = false
            effect.reset()
        }
        if inputIsSilent { flags.pointee.insert(.unitRenderAction_OutputIsSilence) }
        return noErr
    }
}

nonisolated enum PitchEffectTestSignal {
    static func sine(frequency: Double, frames: Int, sampleRate: Double = 44_100) -> [Float] {
        (0..<frames).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate) * 0.1) }
    }

    static func measuredFrequency(_ samples: ArraySlice<Float>, sampleRate: Double) throws -> Double {
        let values = Array(samples)
        var crossings: [Double] = []
        for index in 1..<values.count where values[index - 1] <= 0 && values[index] > 0 {
            let fraction = Double(-values[index - 1] / (values[index] - values[index - 1]))
            crossings.append(Double(index - 1) + fraction)
        }
        let first = try #require(crossings.first)
        let last = try #require(crossings.last)
        try #require(last > first)
        return Double(crossings.count - 1) * sampleRate / (last - first)
    }
}

import AVFoundation

nonisolated extension SpectrumAnalyzer {
    /// Copies one channel of float samples out of a tap buffer, or returns `nil` for data the analyzer
    /// cannot read. `stride` is the number of interleaved channels: the tap delivers the node's
    /// deinterleaved float format (stride 1), and any other layout is skipped rather than misread.
    static func floatSamples(of buffer: AVReadOnlyAudioPCMBuffer, channel: Int) -> [Float]? {
        let count = buffer.frameLength
        guard buffer.stride == 1, case let .float(samples) = buffer.channelData(channel),
              samples.count >= count else { return nil }
        return samples.withUnsafeBufferPointer { Array($0.prefix(count)) }
    }
}

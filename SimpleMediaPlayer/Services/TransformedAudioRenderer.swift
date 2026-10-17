import AVFoundation
import Foundation

nonisolated protocol TransformedAudioRendering: Sendable {
    func render(
        sourceURL: URL,
        pitchCents: Float,
        rate: Float,
        maxSampleRate: Double?,
        makeEncoder: (AVAudioFormat) throws -> any AudioFileEncoding,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> TransformedAudioRenderer.Result
}

nonisolated final class TransformedAudioRenderer: TransformedAudioRendering, @unchecked Sendable {
    struct Result: Sendable {
        let duration: TimeInterval
    }

    func render(
        sourceURL: URL,
        pitchCents: Float,
        rate: Float,
        maxSampleRate: Double?,
        makeEncoder: (AVAudioFormat) throws -> any AudioFileEncoding,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> Result {
        try Task.checkCancellation()
        let source = try ExtendedAudioSource.readableFile(for: sourceURL)
        defer { source.release() }
        let sourceFile = try AVAudioFile(forReading: source.url)
        let session = try TransformedAudioRenderSession(
            sourceFile: sourceFile, pitchCents: pitchCents, rate: rate, maxSampleRate: maxSampleRate
        )
        defer { session.stop() }
        let encoder = try makeEncoder(session.format)
        var didFinishEncoder = false
        defer {
            if didFinishEncoder == false { encoder.cancel() }
        }
        try session.render(to: encoder, progress: progress)
        try Task.checkCancellation()
        try encoder.finish()
        try Task.checkCancellation()
        didFinishEncoder = true
        progress(1)
        return Result(duration: Double(session.expectedFrames) / session.format.sampleRate)
    }
}

nonisolated private final class TransformedAudioRenderSession {
    let format: AVAudioFormat
    let expectedFrames: AVAudioFramePosition
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AudioProcessingQuality.makeTimePitch()
    private let pitchEffect = SMPPitchEffect()
    private let protection = AudioOutputProtection()
    private let maximumFrameCount: AVAudioFrameCount = 4096

    init(sourceFile: AVAudioFile, pitchCents: Float, rate: Float, maxSampleRate: Double?) throws {
        let sourceFormat = sourceFile.processingFormat
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: min(sourceFormat.sampleRate, maxSampleRate ?? sourceFormat.sampleRate),
            channels: min(max(sourceFormat.channelCount, 1), 2),
            interleaved: false
        ) else {
            throw TransformedAudioExportError.invalidRenderFormat
        }
        self.format = format
        pitchEffect.pitchCents = max(-2400, min(2400, pitchCents))
        timePitch.rate = max(0.25, min(4.0, rate))
        timePitch.bypass = timePitch.rate == 1
        let sourceDuration = Double(sourceFile.length) / sourceFormat.sampleRate
        expectedFrames = max(1, AVAudioFramePosition(
            (sourceDuration / Double(timePitch.rate) * format.sampleRate).rounded(.up)
        ))
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(pitchEffect.node)
        protection.attach(to: engine)
        engine.connect(player, to: timePitch, format: sourceFormat)
        engine.connect(timePitch, to: pitchEffect.node, format: sourceFormat)
        engine.connect(pitchEffect.node, to: engine.mainMixerNode, format: sourceFormat)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrameCount)
            try protection.connect(to: engine)
            try engine.start()
            try schedule(sourceFile)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.disableManualRenderingMode()
    }

    private func schedule(_ sourceFile: AVAudioFile) throws {
        // An exhausted player can flag silence without pulling the effect's delayed samples.
        // Feed actual zero PCM so the pitch processor and limiter drain across render boundaries.
        let paddingFrames = AVAudioFrameCount(max(
            Double(maximumFrameCount),
            ((pitchEffect.latency + protection.latency + protection.tailTime) * sourceFile.processingFormat.sampleRate
                * Double(timePitch.rate)).rounded(.up)
        ))
        guard let padding = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: paddingFrames),
              let channels = padding.floatChannelData else {
            throw TransformedAudioExportError.invalidRenderFormat
        }
        padding.frameLength = paddingFrames
        for channel in 0..<Int(padding.format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(paddingFrames))
        }
        player.scheduleFile(sourceFile, at: nil)
        player.scheduleBuffer(padding)
        player.play()
    }

    func render(to encoder: any AudioFileEncoding, progress: @escaping @Sendable (Double) -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrameCount) else {
            throw TransformedAudioExportError.invalidRenderFormat
        }
        // Latency is reported in seconds; round to the nearest sample, avoiding 96.000004 -> 97.
        var leadingFrames = AVAudioFramePosition(
            ((pitchEffect.latency + protection.latency) * format.sampleRate).rounded()
        )
        var writtenFrames: AVAudioFramePosition = 0
        var retryCount = 0
        while writtenFrames < expectedFrames {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(min(
                AVAudioFramePosition(maximumFrameCount), expectedFrames - writtenFrames + leadingFrames
            ))
            let status = try engine.renderOffline(remaining, to: buffer)
            if status == .cannotDoInCurrentContext || (status == .success && buffer.frameLength == 0) {
                retryCount += 1
                guard retryCount <= 8 else { throw renderFailed() }
                continue
            }
            // Partial output is not a successful export. Padding should make all requested input available.
            guard status == .success else { throw renderFailed() }
            retryCount = 0
            let skippedFrames = AVAudioFrameCount(min(leadingFrames, AVAudioFramePosition(buffer.frameLength)))
            leadingFrames -= AVAudioFramePosition(skippedFrames)
            trimLeadingFrames(skippedFrames, from: buffer)
            guard buffer.frameLength > 0 else { continue }
            try encoder.encode(buffer: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            progress(min(1, Double(writtenFrames) / Double(expectedFrames)))
        }
    }

    private func trimLeadingFrames(_ count: AVAudioFrameCount, from buffer: AVAudioPCMBuffer) {
        guard count > 0, let channels = buffer.floatChannelData else { return }
        let remaining = Int(buffer.frameLength - count)
        for channel in 0..<Int(buffer.format.channelCount) {
            memmove(channels[channel], channels[channel] + Int(count), remaining * MemoryLayout<Float>.stride)
        }
        buffer.frameLength = AVAudioFrameCount(remaining)
    }

    private func renderFailed() -> TransformedAudioExportError {
        .renderFailed(L10n.string("The audio renderer could not continue."))
    }
}

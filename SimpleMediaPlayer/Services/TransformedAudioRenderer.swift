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
        let sourceFile = try AVAudioFile(forReading: ExtendedAudioSource.readableURL(for: sourceURL))
        let sourceFormat = sourceFile.processingFormat
        let renderSampleRate = min(sourceFormat.sampleRate, maxSampleRate ?? sourceFormat.sampleRate)
        let renderChannels = min(max(sourceFormat.channelCount, 1), 2)
        guard let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: renderSampleRate,
            channels: renderChannels,
            interleaved: false
        ) else {
            throw TransformedAudioExportError.invalidRenderFormat
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.pitch = max(-2400, min(2400, pitchCents))
        timePitch.rate = max(0.25, min(4.0, rate))

        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: sourceFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: sourceFormat)

        let maximumFrameCount: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maximumFrameCount)
        try engine.start()
        defer {
            playerNode.stop()
            engine.stop()
            engine.disableManualRenderingMode()
        }

        let encoder = try makeEncoder(renderFormat)
        var didFinishEncoder = false
        defer {
            if didFinishEncoder == false {
                encoder.cancel()
            }
        }

        playerNode.scheduleFile(sourceFile, at: nil)
        playerNode.play()

        let sourceDuration = Double(sourceFile.length) / sourceFormat.sampleRate
        let expectedFrames = max(
            AVAudioFramePosition(1),
            AVAudioFramePosition((sourceDuration / Double(timePitch.rate) * renderSampleRate).rounded(.up))
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: maximumFrameCount) else {
            throw TransformedAudioExportError.invalidRenderFormat
        }

        var renderedFrames: AVAudioFramePosition = 0
        var retryCount = 0
        var shouldStopRendering = false
        while renderedFrames < expectedFrames && shouldStopRendering == false {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(min(
                AVAudioFramePosition(maximumFrameCount),
                expectedFrames - renderedFrames
            ))
            let status = try engine.renderOffline(remaining, to: buffer)
            switch status {
            case .success:
                retryCount = 0
                guard buffer.frameLength > 0 else { continue }
                try encoder.encode(buffer: buffer)
                renderedFrames += AVAudioFramePosition(buffer.frameLength)
                progress(min(1, Double(renderedFrames) / Double(expectedFrames)))
            case .cannotDoInCurrentContext:
                retryCount += 1
                if retryCount > 8 {
                    throw TransformedAudioExportError.renderFailed(
                        L10n.string("The audio renderer could not continue.")
                    )
                }
            case .insufficientDataFromInputNode:
                if renderedFrames > 0 {
                    shouldStopRendering = true
                    progress(1)
                } else {
                    throw TransformedAudioExportError.renderFailed(
                        L10n.string("The audio renderer ran out of source data.")
                    )
                }
            case .error:
                throw TransformedAudioExportError.renderFailed(L10n.string("The audio renderer failed."))
            @unknown default:
                throw TransformedAudioExportError.renderFailed(L10n.string("The audio renderer failed."))
            }
        }

        try Task.checkCancellation()
        try encoder.finish()
        try Task.checkCancellation()
        didFinishEncoder = true
        progress(1)
        return Result(duration: Double(renderedFrames) / renderSampleRate)
    }
}

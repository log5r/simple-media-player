import AVFoundation
import AudioToolbox

nonisolated enum AudioProcessingQuality {
    // TimePitch handles tempo only; Signalsmith handles pitch in all rendering paths.
    static func makeTimePitch() -> AVAudioUnitTimePitch {
        let effect = AVAudioUnitTimePitch()
        effect.overlap = 32
        effect.bypass = true
        return effect
    }

    static func makePeakLimiter() -> AVAudioUnitEffect {
        let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
        if #available(macOS 27, iOS 27, *) {
            effect.withAudioUnit { configureLimiter($0) }
        } else {
            configureLimiter(effect.audioUnit)
        }
        return effect
    }

    private static func configureLimiter(_ unit: AudioUnit) {
        // Explicit values avoid the different defaults in SDK comments and running AUs.
        // The +1 dB is undone after limiting, leaving quiet audio at its original level.
        for (parameter, value): (AudioUnitParameterID, Float) in [
            (kLimiterParam_AttackTime, 0.002),
            (kLimiterParam_DecayTime, 0.04),
            (kLimiterParam_PreGain, 1)
        ] {
            let status = AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0)
            assert(status == noErr, "Could not configure the system peak limiter.")
        }
    }
}

// The final mixer does sample-rate/channel conversion. Limit AFTER it so conversion
// cannot produce new over-range samples on the way to the device or encoder.
nonisolated final class AudioOutputProtection {
    private let limiter = AudioProcessingQuality.makePeakLimiter()
    let outputNode = AVAudioUnitEQ(numberOfBands: 0)

    init() {
        outputNode.globalGain = -1
    }

    func attach(to engine: AVAudioEngine) {
        engine.attach(limiter)
        engine.attach(outputNode)
    }

    // Called only while stopped, after activating the audio session or manual rendering.
    // Reconnect on each start: a route change may have changed the device format.
    func connect(to engine: AVAudioEngine) throws {
        // The input format can retain the previous route; output is the device/manual render format.
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TransformedAudioExportError.invalidRenderFormat
        }
        engine.connect(engine.mainMixerNode, to: limiter, format: format)
        engine.connect(limiter, to: outputNode, format: format)
        engine.connect(outputNode, to: engine.outputNode, format: format)
    }

    var latency: TimeInterval {
        if #available(macOS 27, iOS 27, *) {
            limiter.withAUAudioUnit { $0.latency }
        } else {
            limiter.auAudioUnit.latency
        }
    }

    var tailTime: TimeInterval {
        if #available(macOS 27, iOS 27, *) {
            limiter.withAUAudioUnit { $0.tailTime }
        } else {
            limiter.auAudioUnit.tailTime
        }
    }

    func reset() {
        limiter.reset()
        outputNode.reset()
    }
}

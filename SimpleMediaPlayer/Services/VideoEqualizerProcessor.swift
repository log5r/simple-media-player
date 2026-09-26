import AVFoundation
import Synchronization

// MTAudioProcessingTap のリアルタイムコールバックから使うため、process では
// ロック・メモリ確保を行わない。設定変更時に不変の係数スナップショットを作り、
// そのポインタだけをアトミックに差し替える。
nonisolated final class VideoEqualizerProcessor: @unchecked Sendable {
    private struct BiquadCoefficients: Sendable {
        let feedforward0: Float
        let feedforward1: Float
        let feedforward2: Float
        let feedback1: Float
        let feedback2: Float

        static let identity = BiquadCoefficients(
            feedforward0: 1,
            feedforward1: 0,
            feedforward2: 0,
            feedback1: 0,
            feedback2: 0
        )
    }

    private struct BiquadState {
        var delay1: Float = 0
        var delay2: Float = 0
    }

    private final class ConfigurationBox: @unchecked Sendable {
        let isEnabled: Bool
        let preampGain: Float
        let coefficients: [BiquadCoefficients]

        init(settings: EqualizerSettings, sampleRate: Double) {
            isEnabled = settings.isEnabled
            preampGain = pow(10, EqualizerSettings.clampedGain(settings.preampDecibels) / 20)
            coefficients = zip(
                zip(EqualizerSettings.bandFrequencies, EqualizerSettings.bandBandwidths),
                settings.bandGains
            ).map { parameters, gain in
                Self.peakingCoefficients(
                    centerFrequency: parameters.0,
                    bandwidth: Double(parameters.1),
                    gainDecibels: Double(EqualizerSettings.clampedGain(gain)),
                    sampleRate: sampleRate
                )
            }
        }

        private static func peakingCoefficients(
            centerFrequency: Double,
            bandwidth: Double,
            gainDecibels: Double,
            sampleRate: Double
        ) -> BiquadCoefficients {
            guard gainDecibels != 0,
                  sampleRate > 0,
                  centerFrequency > 0,
                  centerFrequency < sampleRate / 2
            else {
                return .identity
            }

            // AVAudioUnitEQ の parametric band と同じ、オクターブ単位の帯域幅を
            // RBJ Audio EQ Cookbook の peaking EQ 係数へ変換する。
            let amplitude = pow(10, gainDecibels / 40)
            let radians = 2 * Double.pi * centerFrequency / sampleRate
            let sine = sin(radians)
            guard abs(sine) > .ulpOfOne else { return .identity }
            let alpha = sine * sinh(log(2) / 2 * bandwidth * radians / sine)
            let cosine = cos(radians)
            let denominator = 1 + alpha / amplitude
            guard denominator.isFinite, abs(denominator) > .ulpOfOne else { return .identity }

            return BiquadCoefficients(
                feedforward0: Float((1 + alpha * amplitude) / denominator),
                feedforward1: Float((-2 * cosine) / denominator),
                feedforward2: Float((1 - alpha * amplitude) / denominator),
                feedback1: Float((-2 * cosine) / denominator),
                feedback2: Float((1 - alpha / amplitude) / denominator)
            )
        }
    }

    private struct ConfigurationState: Sendable {
        var settings: EqualizerSettings
        var sampleRate: Double
        // 公開済みのスナップショットは audio callback が参照し得るため、
        // processor の寿命が終わるまで保持する。
        var retainedConfigurations: [ConfigurationBox] = []
    }

    private let configurationAddress = Atomic<UInt>(0)
    private let configurationState: Mutex<ConfigurationState>

    // prepare/process は同じ tap の audio callback から直列に呼ばれる。
    private var filterStates: [BiquadState] = []
    private var preparedChannelCount = 0
    private var lastConfigurationAddress: UInt = 0
    private var lastConfigurationWasEnabled = false

    init(settings: EqualizerSettings = .flat) {
        configurationState = Mutex(ConfigurationState(settings: settings, sampleRate: 48_000))
        publishConfiguration(settings: settings, sampleRate: 48_000)
    }

    func setSettings(_ settings: EqualizerSettings) {
        configurationState.withLock { state in
            state.settings = settings
            publishConfiguration(settings: settings, sampleRate: state.sampleRate, state: &state)
        }
    }

    func prepare(format: AVAudioFormat) {
        let channelCount = Int(format.channelCount)
        preparedChannelCount = channelCount
        filterStates = Array(
            repeating: BiquadState(),
            count: channelCount * EqualizerSettings.bandCount
        )
        lastConfigurationAddress = 0
        lastConfigurationWasEnabled = false

        configurationState.withLock { state in
            state.sampleRate = format.sampleRate
            publishConfiguration(settings: state.settings, sampleRate: format.sampleRate, state: &state)
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData,
              buffer.frameLength > 0
        else {
            return
        }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount == preparedChannelCount,
              filterStates.count == channelCount * EqualizerSettings.bandCount
        else {
            return
        }

        let address = configurationAddress.load(ordering: .acquiring)
        guard address != 0,
              let pointer = UnsafeRawPointer(bitPattern: address)
        else {
            return
        }
        let configuration = Unmanaged<ConfigurationBox>.fromOpaque(pointer).takeUnretainedValue()
        if address != lastConfigurationAddress {
            if configuration.isEnabled, lastConfigurationWasEnabled == false {
                reset()
            }
            lastConfigurationAddress = address
            lastConfigurationWasEnabled = configuration.isEnabled
        }
        guard configuration.isEnabled else { return }

        let frameCount = Int(buffer.frameLength)
        if buffer.format.isInterleaved {
            let samples = channelData[0]
            for channel in 0..<channelCount {
                processChannel(
                    samples,
                    frameCount: frameCount,
                    stride: channelCount,
                    offset: channel,
                    channel: channel,
                    configuration: configuration
                )
            }
        } else {
            for channel in 0..<channelCount {
                processChannel(
                    channelData[channel],
                    frameCount: frameCount,
                    stride: 1,
                    offset: 0,
                    channel: channel,
                    configuration: configuration
                )
            }
        }
    }

    func reset() {
        for index in filterStates.indices {
            filterStates[index] = BiquadState()
        }
    }

    private func processChannel(
        _ samples: UnsafeMutablePointer<Float>,
        frameCount: Int,
        stride: Int,
        offset: Int,
        channel: Int,
        configuration: ConfigurationBox
    ) {
        let stateOffset = channel * EqualizerSettings.bandCount
        for frame in 0..<frameCount {
            let sampleIndex = offset + frame * stride
            var sample = samples[sampleIndex]
            for band in 0..<EqualizerSettings.bandCount {
                let coefficients = configuration.coefficients[band]
                let stateIndex = stateOffset + band
                var state = filterStates[stateIndex]
                let output = coefficients.feedforward0 * sample + state.delay1
                state.delay1 = coefficients.feedforward1 * sample - coefficients.feedback1 * output + state.delay2
                state.delay2 = coefficients.feedforward2 * sample - coefficients.feedback2 * output
                filterStates[stateIndex] = state
                sample = output
            }
            samples[sampleIndex] = sample * configuration.preampGain
        }
    }

    private func publishConfiguration(settings: EqualizerSettings, sampleRate: Double) {
        configurationState.withLock { state in
            publishConfiguration(settings: settings, sampleRate: sampleRate, state: &state)
        }
    }

    private func publishConfiguration(
        settings: EqualizerSettings,
        sampleRate: Double,
        state: inout ConfigurationState
    ) {
        let configuration = ConfigurationBox(settings: settings, sampleRate: sampleRate)
        state.retainedConfigurations.append(configuration)
        let pointer = Unmanaged.passUnretained(configuration).toOpaque()
        configurationAddress.store(UInt(bitPattern: pointer), ordering: .releasing)
    }
}

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

    private struct ChannelLayout {
        let frameCount: Int
        let stride: Int
        let offset: Int
    }

    private struct BiquadState {
        var delay1: Float = 0
        var delay2: Float = 0
    }

    private struct ConfigurationBox {
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

    private struct ConfigurationState: @unchecked Sendable {
        var settings: EqualizerSettings
        var sampleRate: Double
        // The writer retains only the current snapshot and the callback's hazard pointer.
        // Reclamation occurs here, never on the audio callback.
        var retainedConfigurations: [UnsafeMutablePointer<ConfigurationBox>] = []
    }

    private let configurationAddress = Atomic<UInt>(0)
    private let readerAddress = Atomic<UInt>(0)

    var retainedConfigurationCount: Int {
        configurationState.withLock { $0.retainedConfigurations.count }
    }
    private let configurationState: Mutex<ConfigurationState>

    // prepare/process は同じ tap の audio callback から直列に呼ばれる。
    private var filterStates: [BiquadState] = []
    private var preparedChannelCount = 0
    private var isInterleaved = false
    private var isFloat32 = false
    private var lastConfigurationWasEnabled = false

    init(settings: EqualizerSettings = .flat) {
        configurationState = Mutex(ConfigurationState(settings: settings, sampleRate: 48_000))
        publishConfiguration(settings: settings, sampleRate: 48_000)
    }

    deinit {
        configurationState.withLock { state in
            for configuration in state.retainedConfigurations {
                configuration.deinitialize(count: 1)
                configuration.deallocate()
            }
        }
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
        isInterleaved = format.isInterleaved
        isFloat32 = format.commonFormat == .pcmFormatFloat32
        filterStates = Array(
            repeating: BiquadState(),
            count: channelCount * EqualizerSettings.bandCount
        )
        lastConfigurationWasEnabled = false

        configurationState.withLock { state in
            state.sampleRate = format.sampleRate
            publishConfiguration(settings: state.settings, sampleRate: format.sampleRate, state: &state)
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        process(buffer.mutableAudioBufferList, frameCount: Int(buffer.frameLength))
    }

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard isFloat32, frameCount > 0, preparedChannelCount > 0 else { return }
        let channelCount = preparedChannelCount
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        guard list.count >= (isInterleaved ? 1 : channelCount) else { return }
        let stride = isInterleaved ? channelCount : 1
        for channel in 0..<(isInterleaved ? 1 : channelCount) {
            guard list[channel].mData != nil,
                  Int(list[channel].mDataByteSize) >= frameCount * stride * MemoryLayout<Float>.size
            else { return }
        }

        // Sequential consistency closes the load/publish/recheck reclamation race.
        // If publication races this callback, skip one EQ buffer instead of spinning.
        let address = configurationAddress.load(ordering: .sequentiallyConsistent)
        readerAddress.store(address, ordering: .sequentiallyConsistent)
        defer { readerAddress.store(0, ordering: .sequentiallyConsistent) }
        guard address == configurationAddress.load(ordering: .sequentiallyConsistent),
              let pointer = UnsafeRawPointer(bitPattern: address) else { return }
        let configuration = pointer.assumingMemoryBound(to: ConfigurationBox.self)
        // Allocator addresses can be reused, so observe the rendered enabled state
        // independently of the pointer used for snapshot lifetime protection.
        let isEnabled = configuration.pointee.isEnabled
        if isEnabled, lastConfigurationWasEnabled == false { reset() }
        lastConfigurationWasEnabled = isEnabled
        guard isEnabled else { return }

        filterStates.withUnsafeMutableBufferPointer { states in
            configuration.pointee.coefficients.withUnsafeBufferPointer { coefficients in
                for channel in 0..<channelCount {
                    let samples = list[isInterleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                    processChannel(
                        samples,
                        layout: ChannelLayout(
                            frameCount: frameCount, stride: stride, offset: isInterleaved ? channel : 0
                        ),
                        states: states.baseAddress!.advanced(by: channel * EqualizerSettings.bandCount),
                        coefficients: coefficients.baseAddress!, preampGain: configuration.pointee.preampGain
                    )
                }
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
        layout: ChannelLayout,
        states: UnsafeMutablePointer<BiquadState>,
        coefficients: UnsafePointer<BiquadCoefficients>,
        preampGain: Float
    ) {
        for frame in 0..<layout.frameCount {
            let sampleIndex = layout.offset + frame * layout.stride
            var sample = samples[sampleIndex]
            for band in 0..<EqualizerSettings.bandCount {
                let coefficients = coefficients[band]
                var state = states[band]
                let output = coefficients.feedforward0 * sample + state.delay1
                state.delay1 = coefficients.feedforward1 * sample - coefficients.feedback1 * output + state.delay2
                state.delay2 = coefficients.feedforward2 * sample - coefficients.feedback2 * output
                states[band] = state
                sample = output
            }
            samples[sampleIndex] = sample * preampGain
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
        let configuration = UnsafeMutablePointer<ConfigurationBox>.allocate(capacity: 1)
        configuration.initialize(to: ConfigurationBox(settings: settings, sampleRate: sampleRate))
        state.retainedConfigurations.append(configuration)
        let address = UInt(bitPattern: configuration)
        configurationAddress.store(address, ordering: .sequentiallyConsistent)
        let reader = readerAddress.load(ordering: .sequentiallyConsistent)
        state.retainedConfigurations.removeAll {
            let retainedAddress = UInt(bitPattern: $0)
            guard retainedAddress != address && retainedAddress != reader else { return false }
            $0.deinitialize(count: 1)
            $0.deallocate()
            return true
        }
    }
}

import CoreGraphics
import Foundation

nonisolated enum EqualizerReverbPreset: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case smallRoom
    case mediumRoom
    case largeHall

    var id: String { rawValue }

    var name: String {
        switch self {
        case .smallRoom:
            L10n.string("Small Room")
        case .mediumRoom:
            L10n.string("Medium Room")
        case .largeHall:
            L10n.string("Large Hall")
        }
    }
}

nonisolated struct EqualizerSettings: Codable, Equatable, Sendable {
    static let bandFrequencies: [Double] = [
        31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]
    static let bandBandwidths: [Float] = bandFrequencies.indices.map { index in
        let leftSpacing = index > 0
            ? log2(bandFrequencies[index] / bandFrequencies[index - 1])
            : log2(bandFrequencies[1] / bandFrequencies[0])
        let rightSpacing = index < bandFrequencies.index(before: bandFrequencies.endIndex)
            ? log2(bandFrequencies[index + 1] / bandFrequencies[index])
            : log2(bandFrequencies[index] / bandFrequencies[index - 1])
        return Float(max(leftSpacing, rightSpacing))
    }
    static let bandCount = bandFrequencies.count
    static let gainRange: ClosedRange<Float> = -12...12
    static let reverbWetDryMixRange: ClosedRange<Float> = 0...100
    private static let frequencyLayoutVersion = 2
    private static let legacyBandFrequencies: [Double] = [
        60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000
    ]
    static let flat = EqualizerSettings(
        isEnabled: false,
        preampDecibels: 0,
        bandGains: Array(repeating: 0, count: bandCount),
        reverbPreset: .mediumRoom,
        reverbWetDryMix: 0
    )

    var isEnabled: Bool
    var preampDecibels: Float
    var bandGains: [Float]
    var reverbPreset: EqualizerReverbPreset
    var reverbWetDryMix: Float

    private enum CodingKeys: String, CodingKey {
        case frequencyLayoutVersion
        case isEnabled
        case preampDecibels
        case bandGains
        case reverbPreset
        case reverbWetDryMix
    }

    init(
        isEnabled: Bool,
        preampDecibels: Float,
        bandGains: [Float],
        reverbPreset: EqualizerReverbPreset = .mediumRoom,
        reverbWetDryMix: Float = 0
    ) {
        self.isEnabled = isEnabled
        self.preampDecibels = Self.clampedGain(preampDecibels)
        self.bandGains = bandGains.count == Self.bandCount
            ? bandGains.map(Self.clampedGain)
            : Array(repeating: 0, count: Self.bandCount)
        self.reverbPreset = reverbPreset
        self.reverbWetDryMix = Self.clampedReverbWetDryMix(reverbWetDryMix)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let preampDecibels = try container.decode(Float.self, forKey: .preampDecibels)
        let storedBandGains = try container.decode([Float].self, forKey: .bandGains)
        guard storedBandGains.count == Self.bandCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .bandGains,
                in: container,
                debugDescription: "Equalizer settings require exactly \(Self.bandCount) band gains."
            )
        }
        let storedLayoutVersion = try container.decodeIfPresent(Int.self, forKey: .frequencyLayoutVersion)
        let bandGains: [Float]
        switch storedLayoutVersion {
        case nil, 1:
            bandGains = Self.migrateLegacyBandGains(storedBandGains)
        case Self.frequencyLayoutVersion:
            bandGains = storedBandGains
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .frequencyLayoutVersion,
                in: container,
                debugDescription: "Unsupported equalizer frequency layout version."
            )
        }
        self.init(
            isEnabled: isEnabled,
            preampDecibels: preampDecibels,
            bandGains: bandGains,
            reverbPreset: try container.decodeIfPresent(
                EqualizerReverbPreset.self,
                forKey: .reverbPreset
            ) ?? .mediumRoom,
            reverbWetDryMix: try container.decodeIfPresent(Float.self, forKey: .reverbWetDryMix) ?? 0
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.frequencyLayoutVersion, forKey: .frequencyLayoutVersion)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(preampDecibels, forKey: .preampDecibels)
        try container.encode(bandGains, forKey: .bandGains)
        try container.encode(reverbPreset, forKey: .reverbPreset)
        try container.encode(reverbWetDryMix, forKey: .reverbWetDryMix)
    }

    static func load(from defaults: UserDefaults = .standard) -> EqualizerSettings {
        guard let data = defaults.data(forKey: AppSettingsKey.equalizerSettings),
              let settings = try? JSONDecoder().decode(EqualizerSettings.self, from: data)
        else {
            return .flat
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AppSettingsKey.equalizerSettings)
    }

    static func responseCurve(
        preamp: Float,
        bandGains: [Float],
        sampleCount: Int,
        sampleRate: Double = 48_000
    ) -> [CGPoint] {
        guard sampleCount > 0 else { return [] }
        let gains = bandGains.count == bandCount
            ? bandGains.map(clampedGain)
            : Array(repeating: 0, count: bandCount)
        let minimumFrequency = 20.0
        let maximumFrequency = 20_000.0
        let denominator = max(1, sampleCount - 1)

        return (0..<sampleCount).map { index in
            let position = Double(index) / Double(denominator)
            let frequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, position)
            let response = responseDecibels(
                at: frequency,
                preamp: preamp,
                bandGains: gains,
                sampleRate: sampleRate
            )
            return CGPoint(x: position, y: response)
        }
    }

    static func responseDecibels(
        at frequency: Double,
        preamp: Float,
        bandGains: [Float],
        sampleRate: Double = 48_000
    ) -> Double {
        let gains = bandGains.count == bandCount
            ? bandGains.map(clampedGain)
            : Array(repeating: 0, count: bandCount)
        let bandResponse = zip(zip(bandFrequencies, bandBandwidths), gains).reduce(0.0) { partial, entry in
            let ((centerFrequency, bandwidth), gain) = entry
            return partial + peakingResponseDecibels(
                at: frequency,
                centerFrequency: centerFrequency,
                bandwidth: Double(bandwidth),
                gain: Double(gain),
                sampleRate: sampleRate
            )
        }
        return Double(clampedGain(preamp)) + bandResponse
    }

    private static func peakingResponseDecibels(
        at frequency: Double,
        centerFrequency: Double,
        bandwidth: Double,
        gain: Double,
        sampleRate: Double
    ) -> Double {
        guard gain != 0, sampleRate > 0 else { return 0 }
        let nyquistFrequency = sampleRate / 2
        guard frequency > 0,
              frequency < nyquistFrequency,
              centerFrequency < nyquistFrequency
        else { return 0 }

        // AVAudioUnitEQ の parametric band と同じ、オクターブ単位の帯域幅を持つ
        // 標準的な peaking EQ biquad の伝達関数で合成応答を近似する。
        let amplitude = pow(10, gain / 40)
        let centerRadians = 2 * Double.pi * centerFrequency / sampleRate
        let centerSine = sin(centerRadians)
        guard abs(centerSine) > .ulpOfOne else { return 0 }
        let alpha = centerSine * sinh(
            log(2) / 2 * bandwidth * centerRadians / centerSine
        )
        let centerCosine = cos(centerRadians)
        let numeratorZero = 1 + alpha * amplitude
        let numeratorOne = -2 * centerCosine
        let numeratorTwo = 1 - alpha * amplitude
        let denominatorZero = 1 + alpha / amplitude
        let denominatorOne = -2 * centerCosine
        let denominatorTwo = 1 - alpha / amplitude

        let radians = 2 * Double.pi * frequency / sampleRate
        let numeratorReal = numeratorZero + numeratorOne * cos(radians) + numeratorTwo * cos(2 * radians)
        let numeratorImaginary = -(numeratorOne * sin(radians) + numeratorTwo * sin(2 * radians))
        let denominatorReal = denominatorZero + denominatorOne * cos(radians) + denominatorTwo * cos(2 * radians)
        let denominatorImaginary = -(denominatorOne * sin(radians) + denominatorTwo * sin(2 * radians))
        let numeratorPower = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        let denominatorPower = denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        guard numeratorPower > 0, denominatorPower > 0 else { return 0 }
        return 10 * log10(numeratorPower / denominatorPower)
    }

    static func clampedGain(_ gain: Float) -> Float {
        max(gainRange.lowerBound, min(gainRange.upperBound, gain))
    }

    static func clampedReverbWetDryMix(_ mix: Float) -> Float {
        max(reverbWetDryMixRange.lowerBound, min(reverbWetDryMixRange.upperBound, mix))
    }

    private static func migrateLegacyBandGains(_ legacyBandGains: [Float]) -> [Float] {
        let gains = legacyBandGains.map(clampedGain)
        return bandFrequencies.map { frequency in
            guard frequency > legacyBandFrequencies[0] else { return gains[0] }
            guard frequency < legacyBandFrequencies[bandCount - 1] else { return gains[bandCount - 1] }
            guard let upperIndex = legacyBandFrequencies.firstIndex(where: { $0 >= frequency }) else {
                return gains[bandCount - 1]
            }
            let lowerIndex = upperIndex - 1
            let lowerFrequency = legacyBandFrequencies[lowerIndex]
            let upperFrequency = legacyBandFrequencies[upperIndex]
            let interpolation = log2(frequency / lowerFrequency) / log2(upperFrequency / lowerFrequency)
            return gains[lowerIndex] + Float(interpolation) * (gains[upperIndex] - gains[lowerIndex])
        }
    }
}

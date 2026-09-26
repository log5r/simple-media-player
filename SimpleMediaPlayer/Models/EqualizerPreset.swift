import Foundation

nonisolated enum BuiltInEqualizerPreset: String, CaseIterable, Identifiable, Sendable {
    case studio
    case concertHall
    case outdoorStage

    var id: String { rawValue }

    var name: String {
        switch self {
        case .studio:
            L10n.string("Studio")
        case .concertHall:
            L10n.string("Concert Hall")
        case .outdoorStage:
            L10n.string("Outdoor Stage")
        }
    }

    var settings: EqualizerSettings {
        switch self {
        case .studio:
            EqualizerSettings(
                isEnabled: true,
                preampDecibels: -1,
                bandGains: [-1, -0.5, 0, 0.5, 1, 1.5, 1, 0.5, 0, -0.5],
                reverbPreset: .smallRoom,
                reverbWetDryMix: 4
            )
        case .concertHall:
            EqualizerSettings(
                isEnabled: true,
                preampDecibels: -2,
                bandGains: [-1, 0, 0.5, 1, 1.5, 1, 0, -1, -2, -3],
                reverbPreset: .largeHall,
                reverbWetDryMix: 28
            )
        case .outdoorStage:
            EqualizerSettings(
                isEnabled: true,
                preampDecibels: -1.5,
                bandGains: [1, 0.5, 0, -0.5, -1, 0, 1, 1.5, 1, 0],
                reverbPreset: .mediumRoom,
                reverbWetDryMix: 7
            )
        }
    }
}

nonisolated struct UserEqualizerPreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var settings: EqualizerSettings

    init(id: UUID = UUID(), name: String, settings: EqualizerSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    static func load(from defaults: UserDefaults = .standard) -> [UserEqualizerPreset] {
        guard let data = defaults.data(forKey: AppSettingsKey.equalizerUserPresets),
              let presets = try? JSONDecoder().decode([UserEqualizerPreset].self, from: data)
        else {
            return []
        }
        return presets.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    static func save(_ presets: [UserEqualizerPreset], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: AppSettingsKey.equalizerUserPresets)
    }
}

import Foundation

extension PlayerViewModel {
    var canResume: Bool {
        currentItem != nil && isPlaying == false && !isPreparingPlayback
    }

    var hasPitchOrRateAdjustment: Bool {
        pitchSemitones != 0 || abs(playbackRate - 1.0) > 0.001
    }

    var activeEqualizerPresetName: String {
        guard equalizer.isEnabled else { return L10n.string("Off") }
        if let preset = BuiltInEqualizerPreset.allCases.first(where: { $0.settings == equalizer }) {
            return preset.name
        }
        if let preset = userEqualizerPresets.first(where: { $0.settings == equalizer }) {
            return preset.name
        }
        return L10n.string("Custom")
    }

    var canPause: Bool {
        currentItem != nil && (isPlaying || isPreparingPlayback)
    }

    var canStop: Bool {
        currentItem != nil
    }

    var canSkipToNext: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            return false
        }
        return queue.indices.contains(queue.index(after: index))
    }

    var canSkipToPrevious: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            return false
        }
        return index > queue.startIndex
    }
}

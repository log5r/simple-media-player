import Foundation

extension PlayerViewModel {
    func setVolumeNormalizationEnabled(_ enabled: Bool) {
        volumeNormalizationEnabled = enabled
        audioEngine.setVolumeNormalizationEnabled(enabled)
    }

    func setEqualizerEnabled(_ enabled: Bool) {
        updateEqualizer { settings in
            settings.isEnabled = enabled
        }
    }

    func setEqualizerBandGain(index: Int, decibels: Float) {
        guard equalizer.bandGains.indices.contains(index) else { return }
        updateEqualizer { settings in
            settings.bandGains[index] = EqualizerSettings.clampedGain(decibels)
        }
    }

    func setEqualizerPreamp(decibels: Float) {
        updateEqualizer { settings in
            settings.preampDecibels = EqualizerSettings.clampedGain(decibels)
        }
    }

    func setEqualizerReverbPreset(_ preset: EqualizerReverbPreset) {
        updateEqualizer { settings in
            settings.reverbPreset = preset
        }
    }

    func setEqualizerReverbWetDryMix(_ mix: Float) {
        updateEqualizer { settings in
            settings.reverbWetDryMix = EqualizerSettings.clampedReverbWetDryMix(mix)
        }
    }

    func applyEqualizerPreset(_ preset: BuiltInEqualizerPreset) {
        replaceEqualizer(with: preset.settings)
    }

    func applyUserEqualizerPreset(id: UUID) {
        guard let preset = userEqualizerPresets.first(where: { $0.id == id }) else { return }
        var settings = preset.settings
        settings.isEnabled = true
        replaceEqualizer(with: settings)
    }

    func saveCurrentEqualizerPreset(named name: String) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else { return }
        var settings = equalizer
        settings.isEnabled = true
        if let index = userEqualizerPresets.firstIndex(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            userEqualizerPresets[index].name = normalizedName
            userEqualizerPresets[index].settings = settings
        } else {
            userEqualizerPresets.append(UserEqualizerPreset(name: normalizedName, settings: settings))
        }
        UserEqualizerPreset.save(userEqualizerPresets, to: equalizerDefaults)
    }

    func deleteUserEqualizerPreset(id: UUID) {
        userEqualizerPresets.removeAll { $0.id == id }
        UserEqualizerPreset.save(userEqualizerPresets, to: equalizerDefaults)
    }

    func flattenEqualizer() {
        updateEqualizer { settings in
            settings.preampDecibels = 0
            settings.bandGains = Array(repeating: 0, count: EqualizerSettings.bandCount)
            settings.reverbPreset = .mediumRoom
            settings.reverbWetDryMix = 0
        }
    }

    func setVolume(_ value: Double) {
        let clamped = max(0, min(1, value))
        volume = clamped
        if clamped > 0 {
            lastAudibleVolume = clamped
            isMuted = false
        }
        applyVolume()
    }

    func toggleMuted() {
        if isMuted {
            isMuted = false
            if volume == 0 {
                volume = lastAudibleVolume
            }
        } else {
            if volume > 0 {
                lastAudibleVolume = volume
            }
            isMuted = true
        }
        applyVolume()
    }

    func setPitchSemitones(_ value: Int) {
        let clamped = max(Self.pitchSemitoneRange.lowerBound, min(Self.pitchSemitoneRange.upperBound, value))
        pitchSemitones = clamped
        audioEngine.setPitchCents(Float(clamped * 100))
    }

    func setPlaybackRate(_ value: Double) {
        let clamped = max(Self.playbackRateRange.lowerBound, min(Self.playbackRateRange.upperBound, value))
        let quantized = (clamped / Self.playbackRateStep).rounded() * Self.playbackRateStep
        playbackRate = quantized
        audioEngine.setPlaybackRate(Float(quantized))
    }

    func resetPitchAndRate() {
        setPitchSemitones(0)
        setPlaybackRate(1.0)
    }

    func applyVolume() {
        let effectiveVolume = isMuted ? Float(0) : Float(volume)
        audioEngine.setVolume(effectiveVolume)
        videoService.setVolume(effectiveVolume)
    }

    private func updateEqualizer(_ update: (inout EqualizerSettings) -> Void) {
        var settings = equalizer
        update(&settings)
        replaceEqualizer(with: settings)
    }

    private func replaceEqualizer(with settings: EqualizerSettings) {
        equalizer = settings
        audioEngine.setEqualizer(settings)
        videoService.setEqualizer(settings)
        settings.save(to: equalizerDefaults)
    }
}

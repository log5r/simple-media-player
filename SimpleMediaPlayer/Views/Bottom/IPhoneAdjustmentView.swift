#if os(iOS)
import SwiftUI

struct IPhoneAdjustmentView: View {
    let player: PlayerViewModel
    let saveCopy: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showsSavePreset = false
    @State private var presetName = ""
    @State private var presetToDelete: UserEqualizerPreset?

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    IPhoneAdjustmentSteps(label: "Key", value: PitchSpeedTextFormatter.pitch(player.pitchSemitones),
                          downLabel: "Key Down", upLabel: "Key Up",
                          canDecrease: player.pitchSemitones > PlayerViewModel.pitchSemitoneRange.lowerBound,
                          canIncrease: player.pitchSemitones < PlayerViewModel.pitchSemitoneRange.upperBound,
                          decrease: { player.setPitchSemitones(player.pitchSemitones - 1) },
                          increase: { player.setPitchSemitones(player.pitchSemitones + 1) })
                    Button("Reset") { player.setPitchSemitones(0) }.frame(minHeight: 44)
                }.disabled(player.isVideoMode)
                Section("Speed") {
                    IPhoneAdjustmentSteps(label: "Speed", value: PitchSpeedTextFormatter.rate(player.playbackRate),
                          downLabel: "Slower", upLabel: "Faster",
                          canDecrease: player.playbackRate > PlayerViewModel.playbackRateRange.lowerBound,
                          canIncrease: player.playbackRate < PlayerViewModel.playbackRateRange.upperBound,
                          decrease: { player.setPlaybackRate(player.playbackRate - PlayerViewModel.playbackRateStep) },
                          increase: { player.setPlaybackRate(player.playbackRate + PlayerViewModel.playbackRateStep) })
                    Slider(value: Binding(get: { player.playbackRate }, set: { player.setPlaybackRate($0) }),
                           in: PlayerViewModel.playbackRateRange, step: PlayerViewModel.playbackRateStep)
                        .accessibilityLabel("Speed").frame(minHeight: 44)
                    Button("Reset") { player.setPlaybackRate(1) }.frame(minHeight: 44)
                }.disabled(player.isVideoMode)
                equalizer
                Section {
                    Button("Save adjusted copy", systemImage: "square.and.arrow.down", action: saveCopy)
                        .disabled(player.isVideoMode || !player.hasPitchOrRateAdjustment)
                        .frame(minHeight: 44)
                }
            }
            .navigationTitle("Playback Adjustments").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("phoneAdjustmentClose")
                }
            }
        }
        .alert("Save Equalizer Preset", isPresented: $showsSavePreset) {
            TextField("Preset Name", text: $presetName)
            Button("Save") { player.saveCurrentEqualizerPreset(named: presetName); presetName = "" }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { presetName = "" }
        }
        .confirmationDialog("Delete Equalizer Preset?", isPresented: Binding(
            get: { presetToDelete != nil }, set: { if !$0 { presetToDelete = nil } }
        ), presenting: presetToDelete) { preset in
            Button("Delete", role: .destructive) {
                player.deleteUserEqualizerPreset(id: preset.id)
                presetToDelete = nil
            }
        }
    }

    private var equalizer: some View {
        Group {
            Section("Equalizer") {
                Toggle("Equalizer", isOn: Binding(
                    get: { player.equalizer.isEnabled }, set: { player.setEqualizerEnabled($0) }
                ))
                Menu {
                    ForEach(BuiltInEqualizerPreset.allCases) { preset in
                        Button(preset.name) { player.applyEqualizerPreset(preset) }
                    }
                    ForEach(player.userEqualizerPresets) { preset in
                        Button(preset.name) { player.applyUserEqualizerPreset(id: preset.id) }
                    }
                    Divider()
                    Button("Save Equalizer Preset") { showsSavePreset = true }
                    Menu("Delete Equalizer Preset") {
                        ForEach(player.userEqualizerPresets) { preset in
                            Button(preset.name, role: .destructive) { presetToDelete = preset }
                        }
                    }.disabled(player.userEqualizerPresets.isEmpty)
                } label: {
                    LabeledContent("Preset", value: player.activeEqualizerPresetName)
                }.frame(minHeight: 44)
                Button("Flatten") { player.flattenEqualizer() }.frame(minHeight: 44)
            }
            Section("Bands") {
                gainSlider("Preamp", value: player.equalizer.preampDecibels, action: player.setEqualizerPreamp)
                ForEach(EqualizerSettings.bandFrequencies.indices, id: \.self) { index in
                    gainSlider(String(format: "%g Hz", EqualizerSettings.bandFrequencies[index]),
                               value: player.equalizer.bandGains[index]) {
                        player.setEqualizerBandGain(index: index, decibels: $0)
                    }
                }
            }.disabled(!player.equalizer.isEnabled)
            Section("Reverb") {
                Picker("Reverb", selection: Binding(
                    get: { player.equalizer.reverbPreset }, set: { player.setEqualizerReverbPreset($0) }
                )) {
                    ForEach(EqualizerReverbPreset.allCases) { preset in Text(preset.name).tag(preset) }
                }
                Slider(value: Binding(
                    get: { player.equalizer.reverbWetDryMix }, set: { player.setEqualizerReverbWetDryMix($0) }
                ),
                       in: EqualizerSettings.reverbWetDryMixRange)
                    .frame(minHeight: 44).accessibilityLabel("Reverb Mix")
            }.disabled(!player.equalizer.isEnabled)
        }
    }

    private func gainSlider(_ title: String, value: Float, action: @escaping (Float) -> Void) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(L10n.string(String.LocalizationValue(title)))
                Spacer()
                Text(String(format: "%+.1f dB", value)).monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: action), in: EqualizerSettings.gainRange)
                .frame(minHeight: 44).accessibilityLabel(L10n.string(String.LocalizationValue(title)))
        }
    }

}

private struct IPhoneAdjustmentSteps: View {
    let label: String
    let value: String
    let downLabel: String
    let upLabel: String
    let canDecrease: Bool
    let canIncrease: Bool
    let decrease: () -> Void
    let increase: () -> Void

    var body: some View {
        HStack {
            Button(action: decrease) {
                Image(systemName: "minus").frame(width: 44, height: 44).contentShape(Rectangle())
            }
                .accessibilityLabel(L10n.string(String.LocalizationValue(downLabel))).disabled(!canDecrease)
            Spacer()
            Text(value).font(.title2.monospacedDigit())
                .accessibilityLabel(L10n.string(String.LocalizationValue(label))).accessibilityValue(value)
            Spacer()
            Button(action: increase) {
                Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
            }
                .accessibilityLabel(L10n.string(String.LocalizationValue(upLabel))).disabled(!canIncrease)
        }.buttonStyle(.borderless)
    }
}
#endif

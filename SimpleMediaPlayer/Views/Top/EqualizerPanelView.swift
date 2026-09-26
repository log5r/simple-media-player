import SwiftUI

#if os(macOS)
import AppKit
#endif

struct EqualizerPanelView: View {
    let player: PlayerViewModel

    @State private var availableWidth: CGFloat = 0
    @State private var controlsWidth: CGFloat = 0
    @State private var isSavePresetPresented = false
    @State private var presetNameDraft = ""
    @State private var presetToDelete: UserEqualizerPreset?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Equalizer", systemImage: "slider.vertical.3")
                    .fontWeight(.semibold)
                Toggle("Equalizer", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                presetMenu
                Button("Flatten", systemImage: "arrow.counterclockwise") {
                    player.flattenEqualizer()
                }
                .accessibilityIdentifier("flattenEqualizerButton")
                .controlSize(.small)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(.bar)

            // ViewThatFits は不採用: 候補の測定でスライダー群(NSViewRepresentable)を
            // 毎レイアウトパスごとに makeNSView し直し、パネルを開いている間じゅう
            // メインスレッドを浪費してアニメーションを処理落ちさせる。
            // 実幅を onGeometryChange で測って自前で分岐する(幅変化時のみ再評価)。
            Group {
                if showsResponseCurve {
                    HStack(spacing: 12) {
                        equalizerControls
                        Divider()
                        EqualizerCurveView(
                            settings: player.equalizer,
                            sampleRate: player.formatInfo.sampleRateHz ?? 48_000
                        )
                            .frame(minWidth: 150, idealWidth: 210, maxWidth: 260)
                    }
                } else {
                    ScrollView(.horizontal) {
                        equalizerControls
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width in
                availableWidth = width
            })
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .disabled(player.equalizer.isEnabled == false)
            .opacity(player.equalizer.isEnabled ? 1 : 0.55)
        }
        .frame(height: 200)
        .background(.background)
        .overlay(alignment: .top) {
            Divider()
        }
        .alert("Save Equalizer Preset", isPresented: $isSavePresetPresented) {
            TextField("Preset Name", text: $presetNameDraft)
            Button("Save") {
                player.saveCurrentEqualizerPreset(named: presetNameDraft)
                presetNameDraft = ""
            }
            .disabled(trimmedPresetName.isEmpty)
            Button("Cancel", role: .cancel) {
                presetNameDraft = ""
            }
        } message: {
            Text("The current equalizer and ambience settings will be saved.")
        }
        .confirmationDialog(
            "Delete Equalizer Preset?",
            isPresented: Binding(
                get: { presetToDelete != nil },
                set: { if $0 == false { presetToDelete = nil } }
            ),
            presenting: presetToDelete
        ) { preset in
            Button("Delete", role: .destructive) {
                player.deleteUserEqualizerPreset(id: preset.id)
                presetToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                presetToDelete = nil
            }
        } message: { preset in
            Text(L10n.format("Delete “%@”?", preset.name))
        }
    }

    private var trimmedPresetName: String {
        presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var presetMenu: some View {
        Menu {
            Section("Built-in Presets") {
                ForEach(BuiltInEqualizerPreset.allCases) { preset in
                    Button {
                        player.applyEqualizerPreset(preset)
                    } label: {
                        if player.equalizer == preset.settings {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }

            if player.userEqualizerPresets.isEmpty == false {
                Section("User Presets") {
                    ForEach(player.userEqualizerPresets) { preset in
                        Button {
                            player.applyUserEqualizerPreset(id: preset.id)
                        } label: {
                            if player.equalizer == preset.settings {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Save Current Settings…", systemImage: "plus") {
                presetNameDraft = ""
                isSavePresetPresented = true
            }

            if player.userEqualizerPresets.isEmpty == false {
                Menu("Delete User Preset", systemImage: "trash") {
                    ForEach(player.userEqualizerPresets) { preset in
                        Button(preset.name, role: .destructive) {
                            presetToDelete = preset
                        }
                    }
                }
            }
        } label: {
            Label(player.activeEqualizerPresetName, systemImage: "waveform.badge.plus")
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .controlSize(.small)
        .accessibilityIdentifier("equalizerPresetMenu")
    }

    // スライダー群と応答カーブ(最小150)+仕切り+間隔が収まる幅ならカーブ付き、
    // 収まらなければ横スクロールのスライダー群のみ。未測定(0)の間はカーブ付きで開始する
    private var showsResponseCurve: Bool {
        guard availableWidth > 0, controlsWidth > 0 else { return true }
        return availableWidth >= controlsWidth + 12 + 1 + 12 + 150
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { player.equalizer.isEnabled },
            set: { player.setEqualizerEnabled($0) }
        )
    }

    private var equalizerControls: some View {
        HStack(alignment: .top, spacing: 4) {
            sliderColumn(
                label: L10n.string("Preamp"),
                value: player.equalizer.preampDecibels,
                binding: Binding(
                    get: { player.equalizer.preampDecibels },
                    set: { player.setEqualizerPreamp(decibels: $0) }
                ),
                reset: { player.setEqualizerPreamp(decibels: 0) }
            )

            Divider()
                .frame(height: 130)
                .padding(.horizontal, 2)

            ForEach(EqualizerSettings.bandFrequencies.indices, id: \.self) { index in
                sliderColumn(
                    label: frequencyLabel(EqualizerSettings.bandFrequencies[index]),
                    value: player.equalizer.bandGains[index],
                    binding: Binding(
                        get: { player.equalizer.bandGains[index] },
                        set: { player.setEqualizerBandGain(index: index, decibels: $0) }
                    ),
                    reset: { player.setEqualizerBandGain(index: index, decibels: 0) }
                )
            }

            if player.currentItem?.isVideo != true {
                Divider()
                    .frame(height: 130)
                    .padding(.horizontal, 2)

                reverbColumn
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width in
            controlsWidth = width
        })
    }

    private func sliderColumn(
        label: String,
        value: Float,
        binding: Binding<Float>,
        reset: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%+.1f", value))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 31)
            VerticalValueSlider(
                value: binding,
                range: EqualizerSettings.gainRange,
                accessibilityLabel: label,
                accessibilityValue: L10n.format("%+.1f dB", value),
                onReset: reset
            )
                .frame(width: 24, height: 96)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 31)
        }
        .help(L10n.format("%@, %+.1f dB. Double-click to reset.", label, value))
    }

    private var reverbColumn: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.0f%%", player.equalizer.reverbWetDryMix))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42)
            VerticalValueSlider(
                value: Binding(
                    get: { player.equalizer.reverbWetDryMix },
                    set: { player.setEqualizerReverbWetDryMix($0) }
                ),
                range: EqualizerSettings.reverbWetDryMixRange,
                accessibilityLabel: L10n.string("Reverb"),
                accessibilityValue: String(format: "%.0f%%", player.equalizer.reverbWetDryMix),
                onReset: { player.setEqualizerReverbWetDryMix(0) }
            )
            .frame(width: 24, height: 96)
            Menu {
                ForEach(EqualizerReverbPreset.allCases) { preset in
                    Button {
                        player.setEqualizerReverbPreset(preset)
                    } label: {
                        if player.equalizer.reverbPreset == preset {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                Text("Reverb")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 48)
            .help(L10n.format("Reverb Type: %@", player.equalizer.reverbPreset.name))
        }
        .help(L10n.format("Reverb, %.0f%%. Double-click to reset.", player.equalizer.reverbWetDryMix))
    }

    private func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            return String(format: "%gK", frequency / 1_000)
        }
        return String(format: "%g", frequency)
    }
}

struct EqualizerCurveView: View {
    let settings: EqualizerSettings
    let sampleRate: Double

    var body: some View {
        Canvas { context, size in
            let plotRect = CGRect(x: 4, y: 4, width: max(1, size.width - 8), height: max(1, size.height - 8))
            drawGrid(in: &context, rect: plotRect)
            drawResponse(in: &context, rect: plotRect)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Equalizer response curve")
    }

    private func drawGrid(in context: inout GraphicsContext, rect: CGRect) {
        for frequency in EqualizerSettings.bandFrequencies {
            let horizontalPosition = rect.minX + xPosition(for: frequency) * rect.width
            var path = Path()
            path.move(to: CGPoint(x: horizontalPosition, y: rect.minY))
            path.addLine(to: CGPoint(x: horizontalPosition, y: rect.maxY))
            context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
        }

        for decibels in [-12.0, 0.0, 12.0] {
            let verticalPosition = yPosition(for: decibels, in: rect)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: verticalPosition))
            path.addLine(to: CGPoint(x: rect.maxX, y: verticalPosition))
            context.stroke(
                path,
                with: .color(.secondary.opacity(decibels == 0 ? 0.45 : 0.2)),
                style: StrokeStyle(lineWidth: decibels == 0 ? 1 : 0.5, dash: decibels == 0 ? [] : [3, 3])
            )
        }
    }

    private func drawResponse(in context: inout GraphicsContext, rect: CGRect) {
        let points = EqualizerSettings.responseCurve(
            preamp: settings.preampDecibels,
            bandGains: settings.bandGains,
            sampleCount: 120,
            sampleRate: sampleRate
        )
        guard let first = points.first else { return }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + first.x * rect.width, y: yPosition(for: first.y, in: rect)))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x * rect.width, y: yPosition(for: point.y, in: rect)))
        }
        context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    private func yPosition(for decibels: Double, in rect: CGRect) -> CGFloat {
        let displayRange = -24.0...24.0
        let clamped = max(displayRange.lowerBound, min(displayRange.upperBound, decibels))
        let normalized = (displayRange.upperBound - clamped) / (displayRange.upperBound - displayRange.lowerBound)
        return rect.minY + CGFloat(normalized) * rect.height
    }

    private func xPosition(for frequency: Double) -> CGFloat {
        let minimumFrequency = 20.0
        let maximumFrequency = 20_000.0
        let normalized = log(frequency / minimumFrequency) / log(maximumFrequency / minimumFrequency)
        return CGFloat(max(0, min(1, normalized)))
    }
}

#if os(macOS)
struct VerticalValueSlider: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accessibilityLabel: String
    let accessibilityValue: String
    let onReset: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ResettableNSSlider {
        let slider = ResettableNSSlider(
            value: Double(value),
            minValue: Double(range.lowerBound),
            maxValue: Double(range.upperBound),
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isVertical = true
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = false
        slider.tickMarkPosition = .leading
        slider.controlSize = .small
        slider.onDoubleClick = context.coordinator.reset
        updateAccessibility(for: slider)
        return slider
    }

    func updateNSView(_ slider: ResettableNSSlider, context: Context) {
        context.coordinator.parent = self
        slider.isVertical = true
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.floatValue = value
        slider.onDoubleClick = context.coordinator.reset
        updateAccessibility(for: slider)
    }

    private func updateAccessibility(for slider: NSSlider) {
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.setAccessibilityValueDescription(accessibilityValue)
    }

    final class Coordinator: NSObject {
        var parent: VerticalValueSlider

        init(_ parent: VerticalValueSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value = sender.floatValue
        }

        func reset() {
            parent.onReset()
        }
    }
}

final class ResettableNSSlider: NSSlider {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}
#else
struct VerticalValueSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accessibilityLabel: String
    let accessibilityValue: String
    let onReset: () -> Void

    var body: some View {
        Slider(value: $value, in: range)
            .rotationEffect(.degrees(-90))
            .frame(width: 96, height: 24)
            .frame(width: 24, height: 96)
            .onTapGesture(count: 2, perform: onReset)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
    }
}
#endif

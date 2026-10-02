import SwiftUI

struct LEDColorEditor: View {
    let title: LocalizedStringKey
    @Binding var selection: String
    let presets: [LEDColorPreset]
    @State private var customHexInput: String

    init(title: LocalizedStringKey, selection: Binding<String>, presets: [LEDColorPreset]) {
        self.title = title
        _selection = selection
        self.presets = presets
        _customHexInput = State(initialValue: selection.wrappedValue)
    }

    private var normalizedCustomHex: String? {
        LEDColorValue.normalizedHex(customHexInput)
    }

    private var normalizedSelection: String? {
        LEDColorValue.normalizedHex(selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)

            HStack(spacing: 10) {
                ForEach(presets) { preset in
                    Button {
                        applyHex(preset.hex)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(preset.value.color)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.35), lineWidth: 1))

                            Text(preset.name)

                            if normalizedSelection == preset.hex {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack {
                Text("Hex")
                TextField("#RRGGBB", text: $customHexInput)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(title))
                    .accessibilityHint(Text("Hex"))
                    .onSubmit {
                        applyCustomHex()
                    }
                Button("Apply") {
                    applyCustomHex()
                }
                .disabled(normalizedCustomHex == nil)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text("Apply"))
            }

            if normalizedCustomHex == nil {
                Text("Enter a value like #FFFFFF or #4DA3FF.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            customHexInput = selection
        }
        .onChange(of: selection) { _, newValue in
            customHexInput = newValue
        }
    }

    private func applyCustomHex() {
        guard let normalizedHex = normalizedCustomHex else { return }
        applyHex(normalizedHex)
    }

    private func applyHex(_ hex: String) {
        guard let normalizedHex = LEDColorValue.normalizedHex(hex) else { return }
        selection = normalizedHex
        customHexInput = normalizedHex
    }
}

struct IntensitySlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value.formatted(.percent.precision(.fractionLength(0)))))

            HStack {
                Text(range.lowerBound, format: .percent.precision(.fractionLength(0)))
                Spacer()
                Text(range.upperBound, format: .percent.precision(.fractionLength(0)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

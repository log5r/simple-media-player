import SwiftUI

struct PitchSpeedControlsView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let palette: BottomPanelPalette
    let requestSaveCopy: (MediaItem) -> Void

    @State private var showsPitchPopover = false
    @State private var showsSpeedPopover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var targetItem: MediaItem? {
        player.currentItem ?? selectedItem
    }

    private var controlsEnabled: Bool {
        player.isVideoMode == false
    }

    private var canSave: Bool {
        guard let targetItem, targetItem.isVideo == false else { return false }
        return controlsEnabled && player.hasPitchOrRateAdjustment
    }

    var body: some View {
        HStack(spacing: 0) {
            pitchButton
            Divider().background(palette.buttonDivider)
            speedButton
            Divider().background(palette.buttonDivider)
            controlButton(
                identifier: "saveAdjustedCopyButton",
                label: "Save adjusted copy",
                systemName: "square.and.arrow.down",
                active: false,
                isEnabled: canSave
            ) {
                if let targetItem {
                    requestSaveCopy(targetItem)
                }
            }
            .help(L10n.string("Save adjusted copy"))
        }
        .frame(width: 96, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.controlStroke, lineWidth: 1))
        .shadow(color: palette.buttonShadow, radius: 2, y: 1)
    }

    private var pitchButton: some View {
        controlButton(
            identifier: "pitchButton",
            label: "Key",
            systemName: "tuningfork",
            active: player.pitchSemitones != 0,
            isEnabled: controlsEnabled
        ) {
            showsPitchPopover.toggle()
            showsSpeedPopover = false
        }
        .help(L10n.string("Key"))
        .accessibilityValue(L10n.format("%d semitones", player.pitchSemitones))
        .popover(isPresented: $showsPitchPopover) {
            PitchPopover(player: player)
                .padding(14)
                .frame(width: 210)
        }
    }

    private var speedButton: some View {
        controlButton(
            identifier: "speedButton",
            label: "Speed",
            systemName: "metronome",
            active: abs(player.playbackRate - 1) > 0.001,
            isEnabled: controlsEnabled
        ) {
            showsSpeedPopover.toggle()
            showsPitchPopover = false
        }
        .help(L10n.string("Speed"))
        .accessibilityValue(PitchSpeedTextFormatter.rate(player.playbackRate))
        .popover(isPresented: $showsSpeedPopover) {
            SpeedPopover(player: player)
                .padding(14)
                .frame(width: 230)
        }
    }

    private func controlButton(
        identifier: String,
        label: LocalizedStringKey,
        systemName: String,
        active: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(buttonFill(active: active, isEnabled: isEnabled))
                    .shadow(color: active ? palette.activeButtonShadow : .clear, radius: 9)
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor(active: active, isEnabled: isEnabled))
                    .shadow(color: active ? palette.activeIconShadow : .clear, radius: 3)
            }
            .frame(width: 32, height: 34)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .help(label)
        .zIndex(active ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: active)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isEnabled)
    }

    private func iconColor(active: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return palette.disabledIcon }
        return active ? palette.activeIcon : palette.enabledIcon
    }

    private func buttonFill(active: Bool, isEnabled: Bool) -> AnyShapeStyle {
        if isEnabled == false {
            return AnyShapeStyle(palette.disabledButtonFill)
        }
        return active ? AnyShapeStyle(palette.activeButtonFill) : AnyShapeStyle(palette.normalButtonFill)
    }
}

private struct PitchPopover: View {
    let player: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Key"))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            HStack {
                stepButton(label: "Key Down", systemName: "minus") {
                    player.setPitchSemitones(player.pitchSemitones - 1)
                }
                .disabled(player.pitchSemitones <= PlayerViewModel.pitchSemitoneRange.lowerBound)

                Spacer()
                Text(pitchDisplay)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel(L10n.string("Key"))
                    .accessibilityValue(accessibilityValue)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            player.setPitchSemitones(player.pitchSemitones + 1)
                        case .decrement:
                            player.setPitchSemitones(player.pitchSemitones - 1)
                        @unknown default:
                            break
                        }
                    }
                Spacer()

                stepButton(label: "Key Up", systemName: "plus") {
                    player.setPitchSemitones(player.pitchSemitones + 1)
                }
                .disabled(player.pitchSemitones >= PlayerViewModel.pitchSemitoneRange.upperBound)
            }

            Button(L10n.string("Reset")) {
                player.setPitchSemitones(0)
            }
            .accessibilityIdentifier("pitchResetButton")
            .disabled(player.pitchSemitones == 0)
            .frame(maxWidth: .infinity)
        }
    }

    private var pitchDisplay: String {
        PitchSpeedTextFormatter.pitch(player.pitchSemitones)
    }

    private var accessibilityValue: String {
        L10n.format("%d semitones", player.pitchSemitones)
    }

    private func stepButton(label: LocalizedStringKey, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 26)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(systemName == "minus" ? "pitchDownButton" : "pitchUpButton")
        .help(label)
    }
}

private struct SpeedPopover: View {
    let player: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Speed"))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            HStack {
                stepButton(label: "Slower", systemName: "minus") {
                    player.setPlaybackRate(player.playbackRate - PlayerViewModel.playbackRateStep)
                }
                .disabled(player.playbackRate <= PlayerViewModel.playbackRateRange.lowerBound)

                Spacer()
                Text(PitchSpeedTextFormatter.rate(player.playbackRate))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityHidden(true)
                Spacer()

                stepButton(label: "Faster", systemName: "plus") {
                    player.setPlaybackRate(player.playbackRate + PlayerViewModel.playbackRateStep)
                }
                .disabled(player.playbackRate >= PlayerViewModel.playbackRateRange.upperBound)
            }

            Slider(
                value: Binding(
                    get: { player.playbackRate },
                    set: { player.setPlaybackRate($0) }
                ),
                in: PlayerViewModel.playbackRateRange,
                step: PlayerViewModel.playbackRateStep
            )
            .accessibilityLabel(L10n.string("Speed"))
            .accessibilityValue(PitchSpeedTextFormatter.rate(player.playbackRate))
            HStack {
                Text("×0.50")
                Spacer()
                Text("×1.00")
                Spacer()
                Text("×2.00")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Button(L10n.string("Reset")) {
                player.setPlaybackRate(1.0)
            }
            .accessibilityIdentifier("speedResetButton")
            .disabled(abs(player.playbackRate - 1.0) <= 0.001)
            .frame(maxWidth: .infinity)
        }
    }

    private func stepButton(label: LocalizedStringKey, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 26)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(systemName == "minus" ? "slowerButton" : "fasterButton")
        .help(label)
    }
}

enum PitchSpeedTextFormatter {
    static func pitch(_ semitones: Int) -> String {
        if semitones > 0 { return "+\(semitones)" }
        if semitones < 0 { return "\(semitones)" }
        return "0"
    }

    static func rate(_ value: Double) -> String {
        "×\(String(format: "%.2f", value))"
    }

    static func adjustedTitle(baseTitle: String, pitchSemitones: Int, rate: Double) -> String {
        var parts: [String] = []
        if pitchSemitones != 0 {
            parts.append("Key\(pitchSemitones > 0 ? "+" : "")\(pitchSemitones)")
        }
        if abs(rate - 1.0) > 0.001 {
            parts.append(Self.rate(rate))
        }
        if parts.isEmpty {
            return baseTitle
        }
        return "\(baseTitle) (\(parts.joined(separator: " ")))"
    }
}

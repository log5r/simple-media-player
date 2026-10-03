import SwiftUI

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.usesPhoneLayout) private var usesPhoneLayout
    let player: PlayerViewModel?

    init(player: PlayerViewModel? = nil) {
        self.player = player
    }

    var body: some View {
        NavigationStack {
            Form {
                AppearanceSettingsSection()
                AudioSettingsSection(player: player)
                if !usesPhoneLayout { MediaListSettingsSection() }
                LEDSettingsSection()
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("settingsCloseButton")
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 540)
        #endif
    }
}

private struct LEDSettingsSection: View {
    @Environment(\.usesPhoneLayout) private var usesPhoneLayout
    @AppStorage(AppSettingsKey.bottomPanelLayout)
    private var bottomPanelLayoutRaw = AppSettingsDefault.bottomPanelLayout
    @AppStorage(AppSettingsKey.ledPanelSide) private var ledPanelSideRaw = AppSettingsDefault.ledPanelSide
    @AppStorage(AppSettingsKey.ledPanelCorner) private var ledPanelCornerRaw = AppSettingsDefault.ledPanelCorner
    @AppStorage(AppSettingsKey.ledGlowIntensity) private var ledGlowIntensity = AppSettingsDefault.ledGlowIntensity
    @AppStorage(AppSettingsKey.ledColorHex) private var ledColorHex = AppSettingsDefault.ledColorHex
    @AppStorage(AppSettingsKey.ledBacklitForegroundColorHex)
    private var ledBacklitForegroundColorHex = AppSettingsDefault.ledBacklitForegroundColorHex
    @AppStorage(AppSettingsKey.ledBacklightColorHex)
    private var ledBacklightColorHex = AppSettingsDefault.ledBacklightColorHex
    @AppStorage(AppSettingsKey.ledDisplayStyle) private var ledDisplayStyleRaw = AppSettingsDefault.ledDisplayStyle
    @AppStorage(AppSettingsKey.timeDisplayStyle) private var timeDisplayStyleRaw = AppSettingsDefault.timeDisplayStyle
    @AppStorage(AppSettingsKey.mediaInfoDisplayStyle)
    private var mediaInfoDisplayStyleRaw = AppSettingsDefault.mediaInfoDisplayStyle
    @AppStorage(AppSettingsKey.visualizerResponseMode)
    private var visualizerResponseModeRaw = AppSettingsDefault.visualizerResponseMode
    @AppStorage(AppSettingsKey.ledGlassStyle) private var ledGlassStyleRaw = AppSettingsDefault.ledGlassStyle
    @AppStorage(AppSettingsKey.ledBacklitGlassIntensity)
    private var ledBacklitGlassIntensity = AppSettingsDefault.ledBacklitGlassIntensity
    @AppStorage(AppSettingsKey.dockIconFollowsLEDColor)
    private var dockIconFollowsLEDColor = AppSettingsDefault.dockIconFollowsLEDColor
    @AppStorage(AppSettingsKey.vuMeterFaceColorHex)
    private var vuMeterFaceColorHex = AppSettingsDefault.vuMeterFaceColorHex
    @AppStorage(AppSettingsKey.vuMeterLampColorHex)
    private var vuMeterLampColorHex = AppSettingsDefault.vuMeterLampColorHex
    @AppStorage(AppSettingsKey.vuMeterShadowOpacity)
    private var vuMeterShadowOpacity = AppSettingsDefault.vuMeterShadowOpacity
    @AppStorage(AppSettingsKey.vuMeterShadowExtent)
    private var vuMeterShadowExtent = AppSettingsDefault.vuMeterShadowExtent
    @State private var colorEditorResetID = 0
    private var bottomPanelLayout: BottomPanelLayout {
        BottomPanelLayout(rawValue: bottomPanelLayoutRaw) ?? .ledHalf
    }

    private var ledDisplayStyle: LEDDisplayStyle {
        LEDDisplayStyle(rawValue: ledDisplayStyleRaw) ?? .dark
    }

    private var ledGlassStyle: LEDGlassStyle {
        LEDGlassStyle(rawValue: ledGlassStyleRaw) ?? .off
    }

    private var vuMeterShadowOpacityBinding: Binding<Double> {
        Binding(
            get: { AppSettingsDefault.clampedVUMeterShadowOpacity(vuMeterShadowOpacity) },
            set: { vuMeterShadowOpacity = AppSettingsDefault.clampedVUMeterShadowOpacity($0) }
        )
    }

    private var vuMeterShadowExtentBinding: Binding<Double> {
        Binding(
            get: { AppSettingsDefault.clampedVUMeterShadowExtent(vuMeterShadowExtent) },
            set: { vuMeterShadowExtent = AppSettingsDefault.clampedVUMeterShadowExtent($0) }
        )
    }

    private var clampedLEDBacklitGlassIntensity: Double {
        AppSettingsDefault.clampedLEDBacklitGlassIntensity(ledBacklitGlassIntensity)
    }

    private var ledBacklitGlassIntensityBinding: Binding<Double> {
        Binding(
            get: { clampedLEDBacklitGlassIntensity },
            set: {
                ledBacklitGlassIntensity = AppSettingsDefault.clampedLEDBacklitGlassIntensity($0)
            }
        )
    }

    private var isDefault: Bool {
        bottomPanelLayoutRaw == AppSettingsDefault.bottomPanelLayout
            && ledPanelSideRaw == AppSettingsDefault.ledPanelSide
            && ledPanelCornerRaw == AppSettingsDefault.ledPanelCorner
            && ledGlowIntensity == AppSettingsDefault.ledGlowIntensity
            && ledColorHex == AppSettingsDefault.ledColorHex
            && ledBacklitForegroundColorHex == AppSettingsDefault.ledBacklitForegroundColorHex
            && ledBacklightColorHex == AppSettingsDefault.ledBacklightColorHex
            && ledDisplayStyleRaw == AppSettingsDefault.ledDisplayStyle
            && timeDisplayStyleRaw == AppSettingsDefault.timeDisplayStyle
            && mediaInfoDisplayStyleRaw == AppSettingsDefault.mediaInfoDisplayStyle
            && visualizerResponseModeRaw == AppSettingsDefault.visualizerResponseMode
            && ledGlassStyleRaw == AppSettingsDefault.ledGlassStyle
            && ledBacklitGlassIntensity == AppSettingsDefault.ledBacklitGlassIntensity
            && dockIconFollowsLEDColor == AppSettingsDefault.dockIconFollowsLEDColor
            && vuMeterFaceColorHex == AppSettingsDefault.vuMeterFaceColorHex
            && vuMeterLampColorHex == AppSettingsDefault.vuMeterLampColorHex
            && vuMeterShadowExtent == AppSettingsDefault.vuMeterShadowExtent
            && vuMeterShadowOpacity == AppSettingsDefault.vuMeterShadowOpacity
    }

    var body: some View {
        Section("LED") {
            if !usesPhoneLayout {
                AdaptiveSettingsPicker(
                    title: "Panel Layout", selection: $bottomPanelLayoutRaw,
                    options: BottomPanelLayout.allCases.map { .init(value: $0.rawValue, title: $0.label) },
                    identifier: "ledPicker.bottomPanelLayout"
                )

                if bottomPanelLayout == .ledHalf {
                    AdaptiveSettingsPicker(
                        title: "LED Position", selection: $ledPanelSideRaw,
                        options: LEDPanelSide.allCases.map { .init(value: $0.rawValue, title: $0.label) },
                        identifier: "ledPicker.ledPanelSide"
                    )

                    AdaptiveSettingsPicker(
                        title: "LED Corners", selection: $ledPanelCornerRaw,
                        options: LEDPanelCorner.allCases.map { .init(value: $0.rawValue, title: $0.label) },
                        identifier: "ledPicker.ledPanelCorner"
                    )

                    LEDColorEditor(
                        title: "VU Meter Face",
                        selection: $vuMeterFaceColorHex,
                        presets: AppSettingsDefault.vuMeterFacePresets
                    )
                    .id("vuFace-\(colorEditorResetID)")

                    LEDColorEditor(
                        title: "VU Meter Lamp",
                        selection: $vuMeterLampColorHex,
                        presets: AppSettingsDefault.vuMeterLampPresets
                    )
                    .id("vuLamp-\(colorEditorResetID)")

                    IntensitySlider(
                        title: "VU Shadow Opacity",
                        value: vuMeterShadowOpacityBinding,
                        range: AppSettingsDefault.vuMeterShadowOpacityRange,
                        step: AppSettingsDefault.vuMeterShadowOpacityStep
                    )

                    IntensitySlider(
                        title: "VU Shadow Extent",
                        value: vuMeterShadowExtentBinding,
                        range: AppSettingsDefault.vuMeterShadowExtentRange,
                        step: AppSettingsDefault.vuMeterShadowExtentStep
                    )
                }
            }
            AdaptiveSettingsPicker(
                title: "Display Style", selection: $ledDisplayStyleRaw,
                options: LEDDisplayStyle.allCases.map { .init(value: $0.rawValue, title: $0.label) },
                identifier: "ledPicker.ledDisplayStyle"
            )

            switch ledDisplayStyle {
            case .dark:
                LEDColorEditor(
                    title: "Foreground Color",
                    selection: $ledColorHex,
                    presets: AppSettingsDefault.ledColorPresets
                )
                .id("darkForeground-\(colorEditorResetID)")
            case .backlit:
                LEDColorEditor(
                    title: "Foreground Color",
                    selection: $ledBacklitForegroundColorHex,
                    presets: AppSettingsDefault.ledBacklitForegroundColorPresets
                )
                .id("backlitForeground-\(colorEditorResetID)")

                LEDColorEditor(
                    title: "Backlight Color",
                    selection: $ledBacklightColorHex,
                    presets: AppSettingsDefault.ledBacklightColorPresets
                )
                .id("backlight-\(colorEditorResetID)")
            }

            #if os(macOS)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Match Dock Icon to LED Color", isOn: $dockIconFollowsLEDColor)

                Text("Applies while the app is running. The icon in the Finder does not change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            AdaptiveSettingsPicker(
                title: "Time Display", selection: $timeDisplayStyleRaw,
                options: TimeDisplayStyle.allCases.map { .init(value: $0.rawValue, title: $0.label) },
                identifier: "ledPicker.timeDisplayStyle"
            )

            AdaptiveSettingsPicker(
                title: "Media Info", selection: $mediaInfoDisplayStyleRaw,
                options: MediaInfoDisplayStyle.allCases.map { .init(value: $0.rawValue, title: $0.label) },
                identifier: "ledPicker.mediaInfoDisplayStyle"
            )

            AdaptiveSettingsPicker(
                title: "Glass Effect", selection: $ledGlassStyleRaw,
                options: LEDGlassStyle.allCases.map { .init(value: $0.rawValue, title: $0.label) },
                identifier: "ledPicker.ledGlassStyle"
            )

            if ledDisplayStyle == .backlit, ledGlassStyle != .off {
                IntensitySlider(
                    title: "Glass Intensity",
                    value: ledBacklitGlassIntensityBinding,
                    range: AppSettingsDefault.ledBacklitGlassIntensityRange,
                    step: AppSettingsDefault.ledBacklitGlassIntensityStep
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                AdaptiveSettingsPicker(
                    title: "Spectrum Response", selection: $visualizerResponseModeRaw,
                    options: VisualizerResponseMode.allCases.map { .init(value: $0.rawValue, title: $0.label) },
                    identifier: "ledPicker.visualizerResponseMode"
                )

                Text("Slow uses 10 fps, Normal 30 fps, Fast 60 fps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Glow Intensity")
                    Spacer()
                    Text(ledGlowIntensity.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $ledGlowIntensity,
                    in: AppSettingsDefault.ledGlowIntensityRange,
                    step: AppSettingsDefault.ledGlowIntensityStep
                )

                HStack {
                    Text("Low")
                    Spacer()
                    Text("High")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button("Reset to Defaults") {
                bottomPanelLayoutRaw = AppSettingsDefault.bottomPanelLayout
                ledPanelSideRaw = AppSettingsDefault.ledPanelSide
                ledPanelCornerRaw = AppSettingsDefault.ledPanelCorner
                ledColorHex = AppSettingsDefault.ledColorHex
                ledBacklitForegroundColorHex = AppSettingsDefault.ledBacklitForegroundColorHex
                ledBacklightColorHex = AppSettingsDefault.ledBacklightColorHex
                ledDisplayStyleRaw = AppSettingsDefault.ledDisplayStyle
                ledGlowIntensity = AppSettingsDefault.ledGlowIntensity
                timeDisplayStyleRaw = AppSettingsDefault.timeDisplayStyle
                mediaInfoDisplayStyleRaw = AppSettingsDefault.mediaInfoDisplayStyle
                visualizerResponseModeRaw = AppSettingsDefault.visualizerResponseMode
                ledGlassStyleRaw = AppSettingsDefault.ledGlassStyle
                ledBacklitGlassIntensity = AppSettingsDefault.ledBacklitGlassIntensity
                dockIconFollowsLEDColor = AppSettingsDefault.dockIconFollowsLEDColor
                vuMeterFaceColorHex = AppSettingsDefault.vuMeterFaceColorHex
                vuMeterLampColorHex = AppSettingsDefault.vuMeterLampColorHex
                vuMeterShadowExtent = AppSettingsDefault.vuMeterShadowExtent
                vuMeterShadowOpacity = AppSettingsDefault.vuMeterShadowOpacity
                colorEditorResetID += 1
            }
            .disabled(isDefault)
        }
    }

}

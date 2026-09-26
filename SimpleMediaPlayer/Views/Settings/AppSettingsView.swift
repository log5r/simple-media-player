import SwiftUI

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let player: PlayerViewModel?

    init(player: PlayerViewModel? = nil) {
        self.player = player
    }

    var body: some View {
        NavigationStack {
            Form {
                AppearanceSettingsSection()
                AudioSettingsSection(player: player)
                MediaListSettingsSection()
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

private struct AudioSettingsSection: View {
    let player: PlayerViewModel?
    @AppStorage(AppSettingsKey.volumeNormalizationEnabled)
    private var volumeNormalizationEnabled = AppSettingsDefault.volumeNormalizationEnabled

    var body: some View {
        Section("Audio") {
            Toggle("Automatically Adjust Volume", isOn: $volumeNormalizationEnabled)
                .onChange(of: volumeNormalizationEnabled) { _, enabled in
                    player?.setVolumeNormalizationEnabled(enabled)
                }

            Text(
                """
                Keeps songs at a similar perceived volume. The first playback of each song may take a moment \
                while its level is analyzed.
                """
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AppearanceSettingsSection: View {
    @AppStorage(AppSettingsKey.appearanceMode) private var appearanceModeRaw = AppSettingsDefault.appearanceMode

    var body: some View {
        Section("Display") {
            Picker("Appearance", selection: $appearanceModeRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
        }
    }
}

private struct MediaListSettingsSection: View {
    var body: some View {
        Section("Media List") {
            NavigationLink {
                MediaListColumnsEditorView()
            } label: {
                Label("Edit Columns", systemImage: "tablecolumns")
            }
        }
    }
}

private struct MediaListColumnsEditorView: View {
    @AppStorage(AppSettingsKey.mediaListColumnOrder)
    private var columnOrderRaw = AppSettingsDefault.mediaListColumnOrder
    @AppStorage(AppSettingsKey.mediaListVisibleColumns)
    private var visibleColumnsRaw = AppSettingsDefault.mediaListVisibleColumns
    #if os(macOS)
    @AppStorage(AppSettingsKey.mediaListColumnCustomization)
    private var columnCustomization = TableColumnCustomization<MediaTableRow>()
    #endif

    private var orderedColumns: [MediaListColumn] {
        MediaListColumn.orderedColumns(from: columnOrderRaw)
    }

    private var visibleColumns: Set<MediaListColumn> {
        MediaListColumn.visibleColumnSet(from: visibleColumnsRaw)
    }

    private var isDefault: Bool {
        orderedColumns == Array(MediaListColumn.allCases)
            && visibleColumns == Set(MediaListColumn.defaultVisibleColumns)
    }

    var body: some View {
        List {
            Section {
                ForEach(orderedColumns) { column in
                    columnRow(column)
                }
                .onMove(perform: moveColumns)
            } footer: {
                Text("Drag rows to change the order shown in the media list.")
            }

            Section {
                Button("Reset Columns") {
                    resetColumns()
                }
                .disabled(isDefault)
            }
        }
        .navigationTitle("Columns")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        #endif
    }

    private func columnRow(_ column: MediaListColumn) -> some View {
        let isVisible = visibleColumns.contains(column)
        let isRequired = isVisible && visibleColumns.count == 1

        return HStack(spacing: 12) {
            Image(systemName: isVisible ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isVisible ? Color.accentColor : Color.secondary)
                .imageScale(.large)

            Label(column.settingsTitle, systemImage: column.settingsIconName)

            Spacer()

            if isRequired {
                Text("Required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .foregroundStyle(isRequired ? .secondary : .primary)
        .onTapGesture {
            toggleColumn(column)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isVisible ? .isSelected : [])
        .accessibilityValue(isVisible ? Text("Visible") : Text("Hidden"))
        .accessibilityAction {
            toggleColumn(column)
        }
    }

    private func toggleColumn(_ column: MediaListColumn) {
        var columns = visibleColumns
        if columns.contains(column) {
            guard columns.count > 1 else { return }
            columns.remove(column)
        } else {
            columns.insert(column)
        }
        visibleColumnsRaw = MediaListColumn.encoded(orderedColumns.filter { columns.contains($0) })
        syncTableColumnCustomization()
    }

    private func moveColumns(from source: IndexSet, to destination: Int) {
        var columns = orderedColumns
        columns.move(fromOffsets: source, toOffset: destination)
        columnOrderRaw = MediaListColumn.encoded(columns)
        visibleColumnsRaw = MediaListColumn.encoded(columns.filter { visibleColumns.contains($0) })
    }

    private func resetColumns() {
        columnOrderRaw = AppSettingsDefault.mediaListColumnOrder
        visibleColumnsRaw = AppSettingsDefault.mediaListVisibleColumns
        #if os(macOS)
        columnCustomization = TableColumnCustomization<MediaTableRow>()
        #endif
        syncTableColumnCustomization()
    }

    private func syncTableColumnCustomization() {
        #if os(macOS)
        let visibleColumns = visibleColumns
        for column in MediaListColumn.allCases {
            columnCustomization[visibility: column.rawValue] = visibleColumns.contains(column) ? .visible : .hidden
        }
        #endif
    }
}

private struct LEDSettingsSection: View {
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
        BottomPanelLayout(rawValue: bottomPanelLayoutRaw) ?? .classic
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
            Picker("Panel Layout", selection: $bottomPanelLayoutRaw) {
                ForEach(BottomPanelLayout.allCases) { layout in
                    Text(layout.label).tag(layout.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if bottomPanelLayout == .ledHalf {
                Picker("LED Position", selection: $ledPanelSideRaw) {
                    ForEach(LEDPanelSide.allCases) { side in
                        Text(side.label).tag(side.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("LED Corners", selection: $ledPanelCornerRaw) {
                    ForEach(LEDPanelCorner.allCases) { corner in
                        Text(corner.label).tag(corner.rawValue)
                    }
                }
                .pickerStyle(.segmented)

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

            Picker("Display Style", selection: $ledDisplayStyleRaw) {
                ForEach(LEDDisplayStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)

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

            Picker("Time Display", selection: $timeDisplayStyleRaw) {
                ForEach(TimeDisplayStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("Media Info", selection: $mediaInfoDisplayStyleRaw) {
                ForEach(MediaInfoDisplayStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("Glass Effect", selection: $ledGlassStyleRaw) {
                ForEach(LEDGlassStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if ledDisplayStyle == .backlit, ledGlassStyle != .off {
                IntensitySlider(
                    title: "Glass Intensity",
                    value: ledBacklitGlassIntensityBinding,
                    range: AppSettingsDefault.ledBacklitGlassIntensityRange,
                    step: AppSettingsDefault.ledBacklitGlassIntensityStep
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Spectrum Response", selection: $visualizerResponseModeRaw) {
                    ForEach(VisualizerResponseMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

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

private struct LEDColorEditor: View {
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

private struct IntensitySlider: View {
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

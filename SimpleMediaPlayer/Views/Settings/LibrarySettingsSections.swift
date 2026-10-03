import SwiftUI

struct AudioSettingsSection: View {
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

struct AppearanceSettingsSection: View {
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

struct MediaListSettingsSection: View {
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

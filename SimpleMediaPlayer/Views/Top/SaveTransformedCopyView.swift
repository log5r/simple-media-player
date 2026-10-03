import SwiftData
import SwiftUI

struct SaveTransformedCopyView: View {
    @Environment(\.usesTouchControls) private var usesTouchControls
    let item: MediaItem
    let player: PlayerViewModel
    let libraryService: LibraryService
    let modelContext: ModelContext
    let onComplete: (MediaItem) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var exporter = TransformedTrackExporter()
    @State private var exportTask: Task<Void, Never>?
    @State private var selectedFormatRaw = TransformedExportFormat.aac.rawValue

    init(
        item: MediaItem,
        player: PlayerViewModel,
        libraryService: LibraryService,
        modelContext: ModelContext,
        onComplete: @escaping (MediaItem) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.player = player
        self.libraryService = libraryService
        self.modelContext = modelContext
        self.onComplete = onComplete
        self.onCancel = onCancel
        _title = State(initialValue: PitchSpeedTextFormatter.adjustedTitle(
            baseTitle: item.title,
            pitchSemitones: player.pitchSemitones,
            rate: player.playbackRate
        ))
    }

    private var selectedFormat: TransformedExportFormat {
        TransformedExportFormat(rawValue: selectedFormatRaw) ?? .aac
    }

    private var canSave: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && exporter.isExporting == false
            && selectedFormat.isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Save Adjusted Copy"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("New Title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.string("New Title"), text: $title)
                    .disabled(exporter.isExporting)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Format"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L10n.string("Format"), selection: $selectedFormatRaw) {
                    ForEach(TransformedExportFormat.allCases) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
                .labelsHidden()
                .disabled(exporter.isExporting)
            }

            HStack(spacing: 18) {
                Text("\(L10n.string("Key")): \(PitchSpeedTextFormatter.pitch(player.pitchSemitones))")
                Text("\(L10n.string("Speed")): \(PitchSpeedTextFormatter.rate(player.playbackRate))")
            }
            .font(.subheadline)

            Text(L10n.string("Tags other than the title are inherited from the original track."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if selectedFormat.supportsEmbeddedTags == false {
                Text(L10n.string("This format keeps tags in the library only; they are not embedded in the file."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if selectedFormat == .mp3 && MP3Encoder.isAvailable == false {
                Text(L10n.string("MP3 export requires the LAME encoder. Install lame or choose another format."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if exporter.isExporting {
                ProgressView(value: exporter.progress)
            }

            if let message = exporter.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel")) {
                    if exporter.isExporting {
                        exportTask?.cancel()
                    } else {
                        onCancel()
                    }
                }
                Button(L10n.string("Save")) {
                    startExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canSave == false)
            }
        }
        .padding(22)
        .platformEditorFrame(width: 460)
        .onDisappear {
            exportTask?.cancel()
        }
    }

    private func startExport() {
        guard canSave else { return }

        let format = selectedFormat
        let exportTitle = title
        let pitchSemitones = player.pitchSemitones
        let playbackRate = player.playbackRate

        exportTask = Task {
            do {
                let newItem = try await exporter.export(
                    item: item,
                    title: exportTitle,
                    format: format,
                    pitchSemitones: pitchSemitones,
                    rate: playbackRate,
                    libraryService: libraryService,
                    context: modelContext
                )
                onComplete(newItem)
            } catch is CancellationError {
                exporter.errorMessage = nil
            } catch {
                exporter.errorMessage = L10n.format("Could not export: %@", error.localizedDescription)
            }
        }
    }
}

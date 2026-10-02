import SwiftData
import SwiftUI

struct LyricsEditorView: View {
    let item: MediaItem
    let libraryService: LibraryService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var lyrics: String
    @State private var saveLocation = LyricsSaveLocation.applicationOnly
    @State private var isSaving = false
    @State private var saveError: String?

    init(item: MediaItem, libraryService: LibraryService) {
        self.item = item
        self.libraryService = libraryService
        _lyrics = State(initialValue: item.lyricsRaw ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $lyrics)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .accessibilityLabel("Lyrics")

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Save Location")
                        .font(.headline)

                    Picker("Save Location", selection: $saveLocation) {
                        Text("App Only")
                            .tag(LyricsSaveLocation.applicationOnly)
                        Text("Embed in File")
                            .tag(LyricsSaveLocation.embeddedTag)
                            .disabled(canEmbedLyrics == false)
                    }
                    .pickerStyle(.segmented)

                    Text(saveLocation.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if canEmbedLyrics == false {
                        Label("This file format does not support embedded lyrics editing.", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .background(.bar)
            }
            .navigationTitle(
                item.lyricsRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? "Edit Lyrics" : "Add Lyrics"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Saving…")
                        .padding(16)
                        .background(.regularMaterial, in: .rect(cornerRadius: 10))
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 560, minHeight: 400, idealHeight: 520)
    }

    private var canEmbedLyrics: Bool {
        libraryService.canEditEmbeddedMetadata(for: item)
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task {
            do {
                try await libraryService.saveLyrics(
                    lyrics,
                    for: item,
                    embedInFile: saveLocation == .embeddedTag,
                    in: modelContext
                )
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private enum LyricsSaveLocation: Hashable {
    case applicationOnly
    case embeddedTag

    var explanation: LocalizedStringKey {
        switch self {
        case .applicationOnly:
            "Lyrics are saved in this app without changing the media file."
        case .embeddedTag:
            "Lyrics are saved in this app and embedded in the media file."
        }
    }
}

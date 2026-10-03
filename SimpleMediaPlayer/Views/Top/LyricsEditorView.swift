import SwiftData
import SwiftUI

struct LyricsEditorView: View {
    let item: MediaItem
    let libraryService: LibraryService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.usesPhoneLayout) private var usesPhoneLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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

                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView { saveOptions }
                        .background(.bar)
                } else {
                    saveOptions
                }
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
        .frame(
            minWidth: usesPhoneLayout ? nil : 420,
            idealWidth: usesPhoneLayout ? nil : 560,
            minHeight: usesPhoneLayout ? nil : 400,
            idealHeight: usesPhoneLayout ? nil : 520
        )
    }

    private var saveOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !usesPhoneLayout && !dynamicTypeSize.isAccessibilitySize {
                Text("Save Location")
                    .font(.headline)
            }

            AdaptiveSettingsPicker(
                title: "Save Location", selection: $saveLocation,
                options: [
                    .init(value: .applicationOnly, title: L10n.string("App Only")),
                    .init(value: .embeddedTag, title: L10n.string("Embed in File"), isEnabled: canEmbedLyrics)
                ],
                identifier: "lyricsSaveLocation"
            )

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

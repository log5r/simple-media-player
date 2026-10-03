import SwiftData
import SwiftUI

struct LyricsEditorView: View {
    let item: MediaItem
    let libraryService: LibraryService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.usesTouchControls) private var usesTouchControls
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var lyrics: String
    @State private var saveLocation = LyricsSaveLocation.applicationOnly
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var canEmbedLyrics = false
    @State private var isCheckingEditability = true
    @State private var editabilityRequestID: UUID?

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
            minWidth: usesTouchControls ? nil : 420,
            idealWidth: usesTouchControls ? nil : 560,
            minHeight: usesTouchControls ? nil : 400,
            idealHeight: usesTouchControls ? nil : 520
        )
        .task(id: item.id) {
            await loadEditability()
        }
        .onDisappear {
            editabilityRequestID = nil
        }
        #if DEBUG && os(iOS)
        .modifier(DuoEditorDiagnostics(
            kind: "lyrics", itemID: item.id,
            draft: ["lyrics": lyrics, "saveLocation": saveLocation == .embeddedTag ? "embedded" : "app"],
            isBusy: isSaving
        ))
        #endif
    }

    private var saveOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !usesTouchControls && !dynamicTypeSize.isAccessibilitySize {
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

            if isCheckingEditability {
                ProgressView("Checking metadata editability…")
                    .font(.caption)
            } else if canEmbedLyrics == false {
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

    private func loadEditability() async {
        let itemID = item.id
        let requestID = UUID()
        editabilityRequestID = requestID
        canEmbedLyrics = false
        isCheckingEditability = true
        guard let isEditable = try? await libraryService.canEditEmbeddedMetadata(for: item),
              Task.isCancelled == false, editabilityRequestID == requestID, item.id == itemID,
              item.isDeleted == false, item.modelContext === modelContext else { return }
        canEmbedLyrics = isEditable
        isCheckingEditability = false
        if isEditable == false { saveLocation = .applicationOnly }
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

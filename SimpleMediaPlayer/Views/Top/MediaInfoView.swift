import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MediaInfoView: View {
    let item: MediaItem
    let libraryService: LibraryService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var details: MediaInfoDetails?
    @State private var metadataLoadRequestID: UUID?
    @State private var metadataDraftItemID: UUID?
    @State private var metadataDraft = MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "")
    @State private var originalMetadataDraft = MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "")
    @State private var canEditEmbeddedMetadata = false
    @State private var isSavingMetadata = false
    @State private var metadataSaveError: String?
    @State private var didSaveMetadata = false
    @State private var isDiscardChangesConfirmationPresented = false
    @State private var isArtworkImporterPresented = false
    @State private var artworkLoadError: String?
    @State private var artworkLoadRequestID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ArtworkView(
                    data: metadataDraftItemID == item.id ? metadataDraft.artworkData : nil,
                    isVideo: item.isVideo,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(item.isVideo ? L10n.string("Video") : L10n.string("Audio"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let details {
                        if let errorMessage = details.errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        metadataEditSection
                        infoSection(title: L10n.string("File Details"), rows: details.fileRows)
                        infoSection(title: L10n.string("Summary"), rows: details.summaryRows)
                        ForEach(details.sections) { section in
                            infoSection(title: section.title, rows: section.rows)
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(22)
            }
            .frame(minHeight: EditorLayoutMetrics.minimumScrollHeight)
            Divider()
            HStack {
                Spacer()
                Button("Close") {
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .platformEditorFrame(width: 680, height: 720)
        .alert("Tags have been changed. Close without saving?", isPresented: $isDiscardChangesConfirmationPresented) {
            Button("Close Without Saving", role: .destructive) {
                dismiss()
            }
            Button("Save and Close") {
                saveMetadata(dismissAfterSave: true)
            }
            Button("Continue Editing", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $isArtworkImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleArtworkSelection
        )
        .task(id: [item.id, item.artworkID]) {
            await loadMetadata()
        }
        .onDisappear {
            metadataLoadRequestID = nil
            artworkLoadRequestID = nil
        }
    }

    private var metadataEditSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Editable Metadata")
                .font(.headline)
            artworkEditRow
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                editableRow(label: L10n.string("Title"), text: $metadataDraft.title)
                editableRow(label: L10n.string("Artist"), text: $metadataDraft.artist)
                editableRow(label: L10n.string("Album"), text: $metadataDraft.album)
                editableRow(label: L10n.string("Genre"), text: $metadataDraft.genre)
                editableRow(label: L10n.string("Year"), text: $metadataDraft.year)
                editableNumberPairRow(label: L10n.string("Track"), text: $metadataDraft.trackNumber)
                editableRow(label: L10n.string("Comment"), text: $metadataDraft.comment)
                editableRow(label: L10n.string("Album Artist"), text: $metadataDraft.albumArtist)
                editableRow(label: L10n.string("Composer"), text: $metadataDraft.composer)
                editableNumberPairRow(label: L10n.string("Disc Number"), text: $metadataDraft.discNumber)
                editableToggleRow(label: L10n.string("Compilation"), isOn: $metadataDraft.isCompilation)
            }
            .disabled(canEditEmbeddedMetadata == false || isSavingMetadata)
            HStack(spacing: 10) {
                if let metadataSaveError {
                    Label(metadataSaveError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if didSaveMetadata {
                    Label("Metadata saved.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if canEditEmbeddedMetadata == false {
                    Label(
                        "Text tags cannot be edited for this format. Artwork is saved in the library.",
                        systemImage: "lock"
                    )
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    saveMetadata()
                } label: {
                    if isSavingMetadata {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .disabled(canSaveMetadata == false)
            }
        }
    }

    private var artworkEditRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("Artwork")
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(data: metadataDraft.artworkData, isVideo: item.isVideo, size: 120)
                HStack(spacing: 8) {
                    Button(L10n.string(metadataDraft.artworkData == nil ? "Add Image…" : "Replace Image…")) {
                        isArtworkImporterPresented = true
                    }
                    if metadataDraft.artworkData != nil {
                        Button("Remove", role: .destructive) {
                            artworkLoadRequestID = nil
                            metadataDraft.artworkData = nil
                            metadataDraft.editsArtwork = true
                            markMetadataChanged()
                        }
                    }
                }
                if let artworkLoadError {
                    Text(artworkLoadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isSavingMetadata)
    }

    private func handleArtworkSelection(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(error) = result {
                artworkLoadError = error.localizedDescription
            }
            return
        }
        artworkLoadError = nil
        let requestID = UUID()
        artworkLoadRequestID = requestID
        Task {
            do {
                let artwork = try await libraryService.loadArtwork(from: url)
                guard Task.isCancelled == false, artworkLoadRequestID == requestID else { return }
                metadataDraft.artworkData = artwork
                metadataDraft.editsArtwork = true
                markMetadataChanged()
            } catch {
                guard Task.isCancelled == false, artworkLoadRequestID == requestID else { return }
                artworkLoadError = error.localizedDescription
            }
        }
    }

    private func markMetadataChanged() {
        metadataSaveError = nil
        didSaveMetadata = false
    }

    private func editableRow(label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: text.wrappedValue) { _, _ in
                    metadataSaveError = nil
                    didSaveMetadata = false
                }
        }
    }

    private func editableNumberPairRow(label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            HStack(spacing: 6) {
                TextField(label, text: numberPairComponent(.current, in: text))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text("/")
                    .foregroundStyle(.secondary)
                TextField(label, text: numberPairComponent(.total, in: text))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private extension MediaInfoView {
    func editableToggleRow(label: String, isOn: Binding<Bool>) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { _, _ in
                    metadataSaveError = nil
                    didSaveMetadata = false
                }
        }
    }

}

private extension MediaInfoView {
    func numberPairComponent(_ component: NumberPairComponent, in text: Binding<String>) -> Binding<String> {
        Binding {
            numberPairParts(text.wrappedValue)[component]
        } set: { newValue in
            var parts = numberPairParts(text.wrappedValue)
            parts[component] = newValue.filter(\.isNumber)
            text.wrappedValue = parts.combinedValue
            metadataSaveError = nil
            didSaveMetadata = false
        }
    }

    func numberPairParts(_ value: String) -> NumberPairParts {
        NumberPairParts(value)
    }

    var canSaveMetadata: Bool {
        isSavingMetadata == false
            && metadataDraftItemID == item.id
            && hasUnsavedMetadataChanges
            && (canEditEmbeddedMetadata || metadataDraft.editsArtwork)
    }

    var hasUnsavedMetadataChanges: Bool {
        metadataDraft != originalMetadataDraft
    }

    func close() {
        if isSavingMetadata == false, hasUnsavedMetadataChanges {
            isDiscardChangesConfirmationPresented = true
        } else {
            dismiss()
        }
    }

}

private extension MediaInfoView {
    func loadMetadata() async {
        // A save refreshes its own draft; an external artwork change must preserve local edits.
        if metadataDraftItemID == item.id, isSavingMetadata || hasUnsavedMetadataChanges { return }
        let itemID = item.id
        let requestID = UUID()
        metadataLoadRequestID = requestID
        metadataDraftItemID = nil
        artworkLoadRequestID = nil
        details = nil
        isSavingMetadata = false
        metadataSaveError = nil
        didSaveMetadata = false
        isDiscardChangesConfirmationPresented = false
        canEditEmbeddedMetadata = false
        guard let isEditable = try? await libraryService.canEditEmbeddedMetadata(for: item),
              isCurrentMetadataRequest(itemID: itemID, requestID: requestID) else { return }
        canEditEmbeddedMetadata = isEditable
        _ = await reloadMetadata(itemID: itemID, requestID: requestID)
    }

    func isCurrentMetadataRequest(itemID: UUID, requestID: UUID) -> Bool {
        Task.isCancelled == false && metadataLoadRequestID == requestID
            && item.id == itemID && item.isDeleted == false && item.modelContext === modelContext
    }

    func reloadMetadata(itemID: UUID, requestID: UUID) async -> Bool {
        while isCurrentMetadataRequest(itemID: itemID, requestID: requestID) {
            let artworkID = item.artworkID
            let loadedDraft: MediaMetadataEditDraft
            do {
                loadedDraft = try await libraryService.editableMetadataDraft(for: item)
            } catch is CancellationError {
                guard isCurrentMetadataRequest(itemID: itemID, requestID: requestID),
                      item.artworkID != artworkID else { return false }
                continue
            } catch {
                return false
            }
            guard isCurrentMetadataRequest(itemID: itemID, requestID: requestID) else { return false }
            guard item.artworkID == artworkID else { continue }
            let loadedDetails = await libraryService.loadMediaInfo(for: item)
            guard isCurrentMetadataRequest(itemID: itemID, requestID: requestID) else { return false }
            // A second window may replace the image during either read. Retry that generation
            // without applying the older draft, including during the refresh after saving.
            guard item.artworkID == artworkID else { continue }
            metadataDraft = loadedDraft
            originalMetadataDraft = loadedDraft
            metadataDraftItemID = itemID
            details = loadedDetails
            return true
        }
        return false
    }

    func saveMetadata(dismissAfterSave: Bool = false) {
        guard canSaveMetadata else { return }
        let itemID = item.id
        let requestID = UUID()
        let draft = metadataDraft.forSaving(comparedTo: originalMetadataDraft)
        metadataLoadRequestID = requestID
        artworkLoadRequestID = nil
        isSavingMetadata = true
        metadataSaveError = nil
        didSaveMetadata = false
        Task {
            defer {
                if metadataLoadRequestID == requestID { isSavingMetadata = false }
            }
            do {
                try await libraryService.updateEmbeddedMetadata(for: item, draft: draft, in: modelContext)
                guard await reloadMetadata(itemID: itemID, requestID: requestID) else { return }
                didSaveMetadata = true
                if dismissAfterSave {
                    dismiss()
                }
            } catch {
                guard isCurrentMetadataRequest(itemID: itemID, requestID: requestID) else { return }
                metadataSaveError = error.localizedDescription
            }
        }
    }
}

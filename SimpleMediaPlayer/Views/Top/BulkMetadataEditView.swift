import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BulkMetadataEditView: View {
    let items: [MediaItem]
    let libraryService: LibraryService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "")
    @State private var appliedFields: Set<MediaMetadataEditField> = []
    @State private var editableItemIDs: Set<UUID> = []
    @State private var editabilityRequestID: UUID?
    @State private var isCheckingEditability = true
    @State private var isSaving = false
    @State private var result: BulkMetadataEditResult?
    @State private var isDiscardChangesConfirmationPresented = false
    @State private var isArtworkImporterPresented = false
    @State private var artworkLoadError: String?
    @State private var artworkLoadRequestID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit Multiple Media")
                        .font(.title3.weight(.semibold))
                    Text(selectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bulkEditSelectionSummary")
                        .accessibilityValue("\(items.count)")
                }
                Spacer()
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    metadataPatchSection
                    statusSection
                }
                .padding(22)
            }
            .frame(minHeight: 420)
            Divider()
            HStack {
                Spacer()
                Button("Close") {
                    close()
                }
                .accessibilityIdentifier("bulkEditCloseButton")
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Apply")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canApply == false)
                .accessibilityIdentifier("bulkEditApplyButton")
            }
            .padding(16)
        }
        .platformEditorFrame(width: 620, height: 600)
        .alert(
            "Changes have not been applied. Close without applying?",
            isPresented: $isDiscardChangesConfirmationPresented
        ) {
            Button("Close Without Applying", role: .destructive) {
                dismiss()
            }
            Button("Continue Editing", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $isArtworkImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleArtworkSelection
        )
        .task(id: items.map(\.id)) {
            artworkLoadRequestID = nil
            await loadEditability()
        }
        .onDisappear {
            artworkLoadRequestID = nil
            editabilityRequestID = nil
        }
    }

    private var metadataPatchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Editable Metadata")
                .font(.headline)
            bulkArtworkRow
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                bulkEditableRow(field: .title, label: L10n.string("Title"), text: $draft.title)
                bulkEditableRow(field: .artist, label: L10n.string("Artist"), text: $draft.artist)
                bulkEditableRow(field: .album, label: L10n.string("Album"), text: $draft.album)
                bulkEditableRow(field: .genre, label: L10n.string("Genre"), text: $draft.genre)
                bulkEditableRow(field: .year, label: L10n.string("Year"), text: $draft.year)
                bulkEditableNumberPairRow(field: .trackNumber, label: L10n.string("Track"), text: $draft.trackNumber)
                bulkEditableRow(field: .comment, label: L10n.string("Comment"), text: $draft.comment)
                bulkEditableRow(field: .albumArtist, label: L10n.string("Album Artist"), text: $draft.albumArtist)
                bulkEditableRow(field: .composer, label: L10n.string("Composer"), text: $draft.composer)
                bulkEditableNumberPairRow(
                    field: .discNumber,
                    label: L10n.string("Disc Number"),
                    text: $draft.discNumber
                )
                bulkEditableToggleRow(
                    field: .isCompilation,
                    label: L10n.string("Compilation"),
                    isOn: $draft.isCompilation
                )
            }
            .disabled(isSaving || isCheckingEditability || editableItems.isEmpty)
        }
    }

    private var bulkArtworkRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle(L10n.string("Artwork"), isOn: fieldBinding(.artwork))
                .labelsHidden()
            Text("Artwork")
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            HStack(alignment: .top, spacing: 12) {
                ArtworkView(data: draft.artworkData, isVideo: false, size: 88)
                VStack(alignment: .leading, spacing: 8) {
                    Button(L10n.string(draft.artworkData == nil ? "Add Image…" : "Replace Image…")) {
                        isArtworkImporterPresented = true
                    }
                    Button("Remove", role: .destructive) {
                        artworkLoadRequestID = nil
                        draft.artworkData = nil
                        appliedFields.insert(.artwork)
                        artworkLoadError = nil
                        clearResult()
                    }
                    if let artworkLoadError {
                        Text(artworkLoadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isSaving)
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCheckingEditability {
                ProgressView("Checking metadata editability…")
                    .accessibilityIdentifier("bulkMetadataEditabilityProgress")
            } else if editableItems.isEmpty, appliedFields.contains(.artwork) == false {
                Label("None of the selected files support editing embedded metadata.", systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else if unsupportedCount > 0 {
                if appliedFields.contains(.artwork) {
                    Label(
                        "Text tags cannot be edited for this format. Artwork is saved in the library.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        """
                        \(unsupportedCount) selected files do not support editing embedded metadata \
                        and will be skipped.
                        """,
                        systemImage: "exclamationmark.triangle"
                    )
                        .foregroundStyle(.secondary)
                }
            }
            if let result {
                if result.failedCount == 0 {
                    Label("\(result.updatedCount) files updated.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "\(result.updatedCount) files updated, \(result.failedCount) failed.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .foregroundStyle(.red)
                    ForEach(Array(result.failures.prefix(3))) { failure in
                        Text("\(failure.fileName): \(failure.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

}

private extension BulkMetadataEditView {
    func bulkEditableRow(field: MediaMetadataEditField, label: String, text: Binding<String>) -> some View {
        GridRow {
            Toggle(label, isOn: fieldBinding(field))
                .labelsHidden()
                .accessibilityIdentifier("bulkEditField.\(field.rawValue)")
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(appliedFields.contains(field) == false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: text.wrappedValue) { _, _ in
                    clearResult()
                }
        }
    }

    func bulkEditableNumberPairRow(
        field: MediaMetadataEditField,
        label: String,
        text: Binding<String>
    ) -> some View {
        GridRow {
            Toggle(label, isOn: fieldBinding(field))
                .labelsHidden()
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
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
            .disabled(appliedFields.contains(field) == false)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func bulkEditableToggleRow(field: MediaMetadataEditField, label: String, isOn: Binding<Bool>) -> some View {
        GridRow {
            Toggle(label, isOn: fieldBinding(field))
                .labelsHidden()
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .disabled(appliedFields.contains(field) == false)
                .onChange(of: isOn.wrappedValue) { _, _ in
                    clearResult()
                }
        }
    }

    func fieldBinding(_ field: MediaMetadataEditField) -> Binding<Bool> {
        Binding {
            appliedFields.contains(field)
        } set: { isIncluded in
            if isIncluded {
                appliedFields.insert(field)
            } else {
                appliedFields.remove(field)
            }
            clearResult()
        }
    }

    func numberPairComponent(_ component: NumberPairComponent, in text: Binding<String>) -> Binding<String> {
        Binding {
            NumberPairParts(text.wrappedValue)[component]
        } set: { newValue in
            var parts = NumberPairParts(text.wrappedValue)
            parts[component] = newValue.filter(\.isNumber)
            text.wrappedValue = parts.combinedValue
            clearResult()
        }
    }

    var patch: MediaMetadataEditPatch {
        MediaMetadataEditPatch(fields: appliedFields, draft: draft)
    }

    var editableItems: [MediaItem] {
        items.filter { $0.isDeleted == false && editableItemIDs.contains($0.id) }
    }

    var targetItems: [MediaItem] {
        appliedFields.contains(.artwork) ? items : editableItems
    }

    var unsupportedCount: Int {
        max(items.count - editableItems.count, 0)
    }

    var selectionSummary: String {
        if isCheckingEditability || editableItems.count == items.count || appliedFields.contains(.artwork) {
            return L10n.format("%d selected", items.count)
        }
        return L10n.format("%d selected, %d editable", items.count, editableItems.count)
    }

    var canApply: Bool {
        isSaving == false && isCheckingEditability == false && patch.isEmpty == false && targetItems.isEmpty == false
    }

    func loadEditability() async {
        let itemIDs = items.map(\.id)
        let requestID = UUID()
        editabilityRequestID = requestID
        editableItemIDs = []
        isCheckingEditability = true
        guard let loadedIDs = try? await libraryService.editableMetadataItemIDs(for: items),
              Task.isCancelled == false, editabilityRequestID == requestID,
              items.map(\.id) == itemIDs else { return }
        editableItemIDs = loadedIDs.intersection(items.filter {
            $0.isDeleted == false && $0.modelContext === modelContext
        }.map(\.id))
        isCheckingEditability = false
    }

    func clearResult() {
        result = nil
    }

    func close() {
        if isSaving == false, patch.isEmpty == false {
            isDiscardChangesConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    func save() {
        guard canApply else { return }
        let selectedTargets = targetItems
        let patch = patch
        isSaving = true
        result = nil
        Task {
            let saveResult = await libraryService.updateEmbeddedMetadata(
                for: selectedTargets,
                patch: patch,
                in: modelContext
            )
            result = saveResult
            if saveResult.failedCount == 0 {
                appliedFields = []
            }
            isSaving = false
        }
    }

    func handleArtworkSelection(_ result: Result<[URL], Error>) {
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
                draft.artworkData = artwork
                appliedFields.insert(.artwork)
                clearResult()
            } catch {
                guard Task.isCancelled == false, artworkLoadRequestID == requestID else { return }
                artworkLoadError = error.localizedDescription
            }
        }
    }
}

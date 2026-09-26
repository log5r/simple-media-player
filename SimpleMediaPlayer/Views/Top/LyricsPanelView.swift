import SwiftUI
import SwiftData

struct LyricsPanelView: View {
    let item: MediaItem?
    let listIndex: Int?
    let libraryService: LibraryService
    @Environment(\.modelContext) private var modelContext
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var selectedContent = PanelContent.lyrics
    #if !os(macOS)
    @State private var isArtworkPreviewPresented = false
    #endif
    @State private var infoItem: MediaItem?
    @State private var lyricsItem: MediaItem?
    @State private var informationDraft: MediaMetadataEditDraft?
    @State private var informationDraftItemID: UUID?
    @State private var informationLoadRequestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Panel Content", selection: $selectedContent) {
                ForEach(PanelContent.allCases) { content in
                    Label(content.title, systemImage: content.systemImage)
                        .tag(content)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.bar)

            switch selectedContent {
            case .lyrics:
                lyricsContent
                    .task(id: item?.id) {
                        guard let item else { return }
                        await libraryService.refreshMissingLyrics(for: item, in: modelContext)
                    }
            case .information:
                informationContent
                    .task(id: item?.id) {
                        await reloadInformation()
                    }
            }
        }
        .background(.background)
        .sheet(isPresented: Binding(
            get: { infoItem != nil },
            set: { if $0 == false { infoItem = nil } }
        ), onDismiss: {
            Task { await reloadInformation() }
        }, content: {
            if let infoItem {
                MediaInfoView(item: infoItem, libraryService: libraryService)
            }
        })
        .sheet(isPresented: Binding(
            get: { lyricsItem != nil },
            set: { if $0 == false { lyricsItem = nil } }
        )) {
            if let lyricsItem {
                LyricsEditorView(item: lyricsItem, libraryService: libraryService)
            }
        }
    }

    private var lyricsContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if parsed.lines.isEmpty || item?.isVideo == true {
                        Text("No lyrics available")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 36)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(parsed.lines) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .id(item?.id)
                        .padding(14)
                    }
                }
                .onChange(of: item?.id) { _, newID in
                    if let newID {
                        proxy.scrollTo(newID, anchor: .top)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    lyricsItem = item
                } label: {
                    Label(lyricsButtonTitle, systemImage: "square.and.pencil")
                }
                .disabled(item == nil || item?.isVideo == true)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var lyricsButtonTitle: LocalizedStringKey {
        parsed.lines.isEmpty ? "Add Lyrics…" : "Edit Lyrics…"
    }

    private func showArtworkPreview(for item: MediaItem) {
        #if os(macOS)
        openWindow(id: ArtworkPreviewWindow.sceneID, value: item.id)
        #else
        isArtworkPreviewPresented = true
        #endif
    }

    #if !os(macOS)
    private func artworkPreview(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Artwork")
            .padding(28)
            .frame(
                minWidth: 420,
                idealWidth: 520,
                maxWidth: 640,
                minHeight: 420,
                idealHeight: 520,
                maxHeight: 640
            )
            .background(.background)
            .overlay(alignment: .topTrailing) {
                Button {
                    isArtworkPreviewPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .help("Close")
                .padding(12)
            }
    }
    #endif

    private var informationContent: some View {
        VStack(spacing: 0) {
            if let item {
                if informationDraftItemID == item.id {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(MediaListColumn.allCases) { column in
                                if column == .artwork {
                                    artworkInformationRow(
                                        item: item,
                                        artworkData: informationArtworkData(for: item)
                                    )
                                } else {
                                    informationRow(
                                        label: column.settingsTitle,
                                        value: informationValue(for: column, item: item)
                                    )
                                }

                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("No Track")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    infoItem = item
                } label: {
                    Label("Edit Information…", systemImage: "pencil")
                }
                .disabled(item == nil || informationDraftItemID != item?.id)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func informationRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func artworkInformationRow(item: MediaItem, artworkData: Data?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(MediaListColumn.artwork.settingsTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let artworkData,
               let image = platformImage(data: artworkData) {
                Button {
                    showArtworkPreview(for: item)
                } label: {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Enlarge Artwork")
                .help("Enlarge Artwork")
                #if !os(macOS)
                .popover(isPresented: $isArtworkPreviewPresented) {
                    artworkPreview(image)
                }
                #endif
            } else {
                Label("No artwork available", systemImage: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func informationValue(for column: MediaListColumn, item: MediaItem) -> String {
        switch column {
        case .index:
            listIndex.map(String.init) ?? "-"
        case .artwork:
            ""
        case .title:
            metadataText(informationDraft.map(\.title) ?? item.title, fallback: item.title)
        case .artist:
            metadataText(informationDraft.map(\.artist) ?? item.artist, fallback: item.displayArtist)
        case .album:
            metadataText(informationDraft.map(\.album) ?? item.album, fallback: item.displayAlbum)
        case .genre:
            metadataText(informationDraft.map(\.genre) ?? item.genre, fallback: item.displayGenre)
        case .duration:
            item.duration.mediaTime
        case .trackNumber:
            metadataText(informationDraft.map(\.trackNumber) ?? item.trackNumber)
        case .year:
            metadataText(informationDraft.map(\.year) ?? item.year)
        case .albumArtist:
            metadataText(informationDraft.map(\.albumArtist) ?? item.albumArtist)
        case .composer:
            metadataText(informationDraft.map(\.composer) ?? item.composer)
        case .discNumber:
            metadataText(informationDraft.map(\.discNumber) ?? item.discNumber)
        case .kind:
            if item.isVideo {
                L10n.string("Video")
            } else {
                L10n.string("Audio")
            }
        case .contentType:
            item.displayContentType
        case .dateAdded:
            item.addedAt.formatted(date: .numeric, time: .omitted)
        case .fileName:
            item.fileName
        }
    }

    private func metadataText(_ value: String?, fallback: String = "-") -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func informationArtworkData(for item: MediaItem) -> Data? {
        guard let informationDraft else { return item.artworkData }
        return informationDraft.artworkData
    }

    private func reloadInformation() async {
        let requestID = UUID()
        informationLoadRequestID = requestID
        informationDraftItemID = nil

        guard let item else {
            informationDraft = nil
            return
        }

        let itemID = item.id
        let draft = await libraryService.editableMetadataDraft(for: item)
        guard Task.isCancelled == false,
              self.item?.id == itemID,
              informationLoadRequestID == requestID else { return }
        informationDraft = draft
        informationDraftItemID = itemID
    }

    private func platformImage(data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }

    private var parsed: ParsedLyrics {
        LyricsParser.parse(item?.lyricsRaw)
    }
}

private struct LyricsEditorView: View {
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

private enum PanelContent: CaseIterable, Identifiable {
    case lyrics
    case information

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .lyrics: "Lyrics"
        case .information: "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .lyrics: "text.quote"
        case .information: "info.circle"
        }
    }
}

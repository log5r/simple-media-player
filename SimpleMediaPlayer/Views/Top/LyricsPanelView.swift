import SwiftUI
import SwiftData

struct LyricsPanelView: View {
    let item: MediaItem?
    let listIndex: Int?
    let libraryService: LibraryService
    var page: PanelContent?
    var playbackPlayer: PlayerViewModel?
    var browsingState: LibraryBrowsingState?
    /// Sheets can share page selection while keeping their nested editors locally presented.
    var contentSelection: Binding<PanelContent>?
    @Environment(\.usesTouchControls) var usesTouchControls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) var modelContext
    #if os(macOS)
    @Environment(\.openWindow) var openWindow
    #endif
    @State private var parsed = ParsedLyrics(lines: [], hasTimeTags: false)
    @State private var selectedContent = PanelContent.lyrics
    #if !os(macOS)
    @State var isArtworkPreviewPresented = false
    #endif
    @State private var infoItem: MediaItem?
    @State private var lyricsItem: MediaItem?
    @State var informationDraft: MediaMetadataEditDraft?
    @State var informationDraftItemID: UUID?
    @State var informationDraftArtworkID: UUID?
    @State var informationLoadRequestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page == nil {
                Picker("Panel Content", selection: selectedContentBinding) {
                    ForEach(PanelContent.allCases) { content in
                        Label(content.title, systemImage: content.systemImage)
                            .tag(content)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("lyricsPanelContentPicker")
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.bar)
            }
            switch page ?? selectedContentBinding.wrappedValue {
            case .lyrics:
                lyricsContent
                    .task(id: item?.id) {
                        guard let item else { return }
                        await libraryService.refreshMissingLyrics(for: item, in: modelContext)
                    }
            case .information:
                informationContent
                    .task(id: [item?.id, item?.artworkID]) {
                        await reloadInformation()
                    }
            }
        }
        .background(.background)
        .onChange(of: item?.lyricsRaw, initial: true) { _, raw in parsed = LyricsParser.parse(raw) }
        .onChange(of: browsingState?.infoItem?.id) { oldID, newID in
            if newID == nil, oldID == item?.id { Task { await reloadInformation() } }
        }
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

    private var selectedContentBinding: Binding<PanelContent> {
        if let contentSelection { return contentSelection }
        return Binding {
            browsingState?.panelContent ?? selectedContent
        } set: { content in
            if let browsingState {
                browsingState.panelContent = content
            } else {
                selectedContent = content
            }
        }
    }

    private var lyricsContent: some View {
        let activeIndex = activeLyricIndex
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if parsed.lines.isEmpty || item?.isVideo == true {
                        Text("No lyrics available")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 36)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(parsed.lines.enumerated()), id: \.offset) { index, line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(usesTouchControls ? .title3 : .system(size: 13))
                                    .fontWeight(activeIndex == index ? .bold : .regular)
                                    .foregroundStyle(activeIndex == index ? Color.accentColor : Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                                    .accessibilityAddTraits(activeIndex == index ? .isSelected : [])
                            }
                        }
                        .id(item?.id)
                        .padding(14)
                    }
                }
                .onChange(of: activeIndex, initial: true) { _, index in
                    guard let index else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo(index, anchor: .center)
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
                    if let browsingState {
                        browsingState.lyricsItem = item
                    } else {
                        lyricsItem = item
                    }
                } label: {
                    Label(lyricsButtonTitle, systemImage: "square.and.pencil")
                        .frame(minHeight: usesTouchControls ? 44 : nil)
                }
                .disabled(item == nil || item?.isVideo == true)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var activeLyricIndex: Int? {
        guard parsed.hasTimeTags, let playbackTime = playbackPlayer?.currentTime else { return nil }
        return parsed.lines.lastIndex { ($0.timestamp ?? .infinity) <= playbackTime }
    }

    private var lyricsButtonTitle: LocalizedStringKey {
        parsed.lines.isEmpty ? "Add Lyrics…" : "Edit Lyrics…"
    }

    #if !os(macOS)
    func artworkPreview(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Artwork")
            .padding(28)
            .frame(
                minWidth: usesTouchControls ? 0 : 420,
                idealWidth: usesTouchControls ? nil : 520,
                maxWidth: usesTouchControls ? .infinity : 640,
                minHeight: usesTouchControls ? 0 : 420,
                idealHeight: usesTouchControls ? nil : 520,
                maxHeight: usesTouchControls ? .infinity : 640
            )
            .background(.background)
            .overlay(alignment: .topTrailing) {
                Button {
                    isArtworkPreviewPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .frame(minWidth: usesTouchControls ? 44 : nil, minHeight: usesTouchControls ? 44 : nil)
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
                    if let browsingState {
                        browsingState.infoItem = item
                    } else {
                        infoItem = item
                    }
                } label: {
                    Label("Edit Information…", systemImage: "pencil")
                        .frame(minHeight: usesTouchControls ? 44 : nil)
                }
                .disabled(item == nil || informationDraftItemID != item?.id)
            }
            .padding(12)
            .background(.bar)
        }
    }

}

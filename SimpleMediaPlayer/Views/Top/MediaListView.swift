import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct MediaListView: View {
    let items: [MediaItem]
    let queue: [MediaItem]
    let section: LibrarySection?
    let activePlaylist: Playlist?
    let playlists: [Playlist]
    let libraryService: LibraryService
    let player: PlayerViewModel
    @Binding var librarySortField: LibrarySortField
    @Binding var librarySortDirection: LibrarySortDirection
    let addToPlaylist: (MediaItem, Playlist) -> Void
    let createPlaylistWithItem: (MediaItem) -> Void
    let removeFromPlaylist: (MediaItem) -> Void
    let movePlaylistItem: (MediaItem, Int) -> Void
    let createAACVersion: (MediaItem) -> Void
    let canCreateAACVersion: Bool
    let deleteItem: (MediaItem) -> Void
    @Binding var selectedItemID: UUID?
    @Binding var isBulkEditMode: Bool
    let bulkSelection: BulkMediaSelectionState

    @AppStorage(AppSettingsKey.mediaListColumnCustomization)
    private var columnCustomization = TableColumnCustomization<MediaTableRow>()
    @AppStorage(AppSettingsKey.mediaListColumnOrder)
    private var columnOrderRaw = AppSettingsDefault.mediaListColumnOrder
    @AppStorage(AppSettingsKey.mediaListVisibleColumns)
    private var visibleColumnsRaw = AppSettingsDefault.mediaListVisibleColumns
    @State private var infoItem: MediaItem?
    @State private var deleteConfirmationItem: MediaItem?
    @State private var tableSortOrder: [KeyPathComparator<MediaTableRow>] = []
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else if section == .albums {
                albumBrowser
            } else if section?.isGrouped == true {
                groupedList
            } else {
                mediaTable
            }
        }
        .background(.background)
        .focusedSceneValue(\.mediaInfoCommandAction, selectedInfoCommandAction)
        .focusedSceneValue(\.aacVersionCommandAction, selectedAACVersionCommandAction)
        .onAppear {
            syncSelectionToCurrentItem()
        }
        .onChange(of: player.currentItem?.id) { _, _ in
            syncSelectionToCurrentItem()
        }
        .onChange(of: isBulkEditMode) { _, isEditing in
            if isEditing == false {
                syncSelectionToCurrentItem()
            }
        }
        .onChange(of: items.map(\.id)) { _, _ in
            if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) == false {
                syncSelectionToCurrentItem()
            }
        }
        .sheet(isPresented: Binding(get: { infoItem != nil }, set: { if $0 == false { infoItem = nil } })) {
            if let infoItem {
                MediaInfoView(item: infoItem, libraryService: libraryService)
            }
        }
        .alert(
            "Delete from Library?",
            isPresented: Binding(
                get: { deleteConfirmationItem != nil }, set: { if $0 == false { deleteConfirmationItem = nil } }
            ),
            presenting: deleteConfirmationItem
        ) { item in
            Button("Delete", role: .destructive) {
                deleteItem(item)
                deleteConfirmationItem = nil
            }
            Button("Cancel", role: .cancel) {
                deleteConfirmationItem = nil
            }
        } message: { item in
            Text(L10n.format("Delete “%@” from your library. This action cannot be undone.", item.title))
        }
    }

    private var albumBrowser: some View {
        AlbumBrowserView(
            items: items,
            player: player,
            selectedItemID: $selectedItemID,
            isBulkEditMode: $isBulkEditMode,
            bulkSelection: bulkSelection,
            itemMenu: { item in
                rowMenu(for: item)
            }
        )
    }

    @ViewBuilder
    private var mediaTable: some View {
        #if os(macOS)
        let tableRows = rows

        Table(
            tableRows,
            selection: tableInteractionSelection,
            sortOrder: tableSortOrderBinding,
            columnCustomization: $columnCustomization
        ) {
            Group {
                TableColumn(MediaListColumn.index.title, value: \MediaTableRow.indexSortValue) { (row: MediaTableRow) in
                    tableCell(for: .index, row: row)
                }
                .width(MediaListColumn.index.idealWidth)
                .defaultVisibility(MediaListColumn.index.defaultVisibility)
                .customizationID(MediaListColumn.index.rawValue)

                TableColumn(
                    MediaListColumn.artwork.title,
                    value: \MediaTableRow.artworkSortValue
                ) { (row: MediaTableRow) in
                    tableCell(for: .artwork, row: row)
                }
                .width(MediaListColumn.artwork.idealWidth)
                .defaultVisibility(MediaListColumn.artwork.defaultVisibility)
                .customizationID(MediaListColumn.artwork.rawValue)

                TableColumn(MediaListColumn.title.title, value: \MediaTableRow.titleSortValue) { row in
                    tableCell(for: .title, row: row)
                }
                .width(min: MediaListColumn.title.minimumWidth, ideal: MediaListColumn.title.idealWidth)
                .defaultVisibility(MediaListColumn.title.defaultVisibility)
                .customizationID(MediaListColumn.title.rawValue)

                TableColumn(MediaListColumn.artist.title, value: \MediaTableRow.artistSortValue) { row in
                    tableCell(for: .artist, row: row)
                }
                .width(min: MediaListColumn.artist.minimumWidth, ideal: MediaListColumn.artist.idealWidth)
                .defaultVisibility(MediaListColumn.artist.defaultVisibility)
                .customizationID(MediaListColumn.artist.rawValue)

                TableColumn(MediaListColumn.album.title, value: \MediaTableRow.albumSortValue) { row in
                    tableCell(for: .album, row: row)
                }
                .width(min: MediaListColumn.album.minimumWidth, ideal: MediaListColumn.album.idealWidth)
                .defaultVisibility(MediaListColumn.album.defaultVisibility)
                .customizationID(MediaListColumn.album.rawValue)

                TableColumn(MediaListColumn.genre.title, value: \MediaTableRow.genreSortValue) { row in
                    tableCell(for: .genre, row: row)
                }
                .width(min: MediaListColumn.genre.minimumWidth, ideal: MediaListColumn.genre.idealWidth)
                .defaultVisibility(MediaListColumn.genre.defaultVisibility)
                .customizationID(MediaListColumn.genre.rawValue)

                TableColumn(MediaListColumn.duration.title, value: \MediaTableRow.durationSortValue) { row in
                    tableCell(for: .duration, row: row)
                }
                .width(MediaListColumn.duration.idealWidth)
                .defaultVisibility(MediaListColumn.duration.defaultVisibility)
                .customizationID(MediaListColumn.duration.rawValue)
            }

            Group {
                TableColumn(MediaListColumn.trackNumber.title, value: \MediaTableRow.trackNumberSortValue) { row in
                    tableCell(for: .trackNumber, row: row)
                }
                .width(min: MediaListColumn.trackNumber.minimumWidth, ideal: MediaListColumn.trackNumber.idealWidth)
                .defaultVisibility(MediaListColumn.trackNumber.defaultVisibility)
                .customizationID(MediaListColumn.trackNumber.rawValue)

                TableColumn(MediaListColumn.year.title, value: \MediaTableRow.yearSortValue) { row in
                    tableCell(for: .year, row: row)
                }
                .width(min: MediaListColumn.year.minimumWidth, ideal: MediaListColumn.year.idealWidth)
                .defaultVisibility(MediaListColumn.year.defaultVisibility)
                .customizationID(MediaListColumn.year.rawValue)

                TableColumn(MediaListColumn.albumArtist.title, value: \MediaTableRow.albumArtistSortValue) { row in
                    tableCell(for: .albumArtist, row: row)
                }
                .width(min: MediaListColumn.albumArtist.minimumWidth, ideal: MediaListColumn.albumArtist.idealWidth)
                .defaultVisibility(MediaListColumn.albumArtist.defaultVisibility)
                .customizationID(MediaListColumn.albumArtist.rawValue)

                TableColumn(MediaListColumn.composer.title, value: \MediaTableRow.composerSortValue) { row in
                    tableCell(for: .composer, row: row)
                }
                .width(min: MediaListColumn.composer.minimumWidth, ideal: MediaListColumn.composer.idealWidth)
                .defaultVisibility(MediaListColumn.composer.defaultVisibility)
                .customizationID(MediaListColumn.composer.rawValue)

                TableColumn(MediaListColumn.discNumber.title, value: \MediaTableRow.discNumberSortValue) { row in
                    tableCell(for: .discNumber, row: row)
                }
                .width(min: MediaListColumn.discNumber.minimumWidth, ideal: MediaListColumn.discNumber.idealWidth)
                .defaultVisibility(MediaListColumn.discNumber.defaultVisibility)
                .customizationID(MediaListColumn.discNumber.rawValue)

                TableColumn(MediaListColumn.kind.title, value: \MediaTableRow.kindSortValue) { row in
                    tableCell(for: .kind, row: row)
                }
                .width(min: MediaListColumn.kind.minimumWidth, ideal: MediaListColumn.kind.idealWidth)
                .defaultVisibility(MediaListColumn.kind.defaultVisibility)
                .customizationID(MediaListColumn.kind.rawValue)

                TableColumn(MediaListColumn.contentType.title, value: \MediaTableRow.contentTypeSortValue) { row in
                    tableCell(for: .contentType, row: row)
                }
                .width(min: MediaListColumn.contentType.minimumWidth, ideal: MediaListColumn.contentType.idealWidth)
                .defaultVisibility(MediaListColumn.contentType.defaultVisibility)
                .customizationID(MediaListColumn.contentType.rawValue)

                TableColumn(MediaListColumn.dateAdded.title, value: \MediaTableRow.dateAddedSortValue) { row in
                    tableCell(for: .dateAdded, row: row)
                }
                .width(min: MediaListColumn.dateAdded.minimumWidth, ideal: MediaListColumn.dateAdded.idealWidth)
                .defaultVisibility(MediaListColumn.dateAdded.defaultVisibility)
                .customizationID(MediaListColumn.dateAdded.rawValue)

                TableColumn(MediaListColumn.fileName.title, value: \MediaTableRow.fileNameSortValue) { row in
                    tableCell(for: .fileName, row: row)
                }
                .width(min: MediaListColumn.fileName.minimumWidth, ideal: MediaListColumn.fileName.idealWidth)
                .defaultVisibility(MediaListColumn.fileName.defaultVisibility)
                .customizationID(MediaListColumn.fileName.rawValue)
            }
        }
        .modifier(FocusOnTapModifier()).overlay {
            TableBulkSelectionInputBridge(
                isEnabled: isBulkEditMode,
                selection: bulkSelection,
                rowIDs: tableRows.map(\.id)
            )
        }
        .contextMenu(forSelectionType: UUID.self) { selection in
            if isBulkEditMode == false, let item = item(in: selection) {
                rowMenu(for: item)
            }
        } primaryAction: { selection in
            if isBulkEditMode == false {
                playSelection(selection)
            }
        }
        #else
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { row in
                        mobileTableRow(row, columns: visibleMediaListColumns)
                    }
                } header: {
                    mobileTableHeader(columns: visibleMediaListColumns)
                }
            }
            .frame(minWidth: mobileTableWidth(for: visibleMediaListColumns), alignment: .leading)
        }
        .background(.background)
        #endif
    }

    private var visibleMediaListColumns: [MediaListColumn] {
        MediaListColumn.visibleColumns(
            orderRawValue: columnOrderRaw,
            visibleRawValue: visibleColumnsRaw
        )
    }

    private var tableSortOrderBinding: Binding<[KeyPathComparator<MediaTableRow>]> {
        Binding {
            activePlaylist == nil ? tableSortOrder : []
        } set: { newValue in
            guard activePlaylist == nil, let comparator = newValue.first else { return }
            tableSortOrder = newValue
            guard let field = MediaTableRow.sortField(
                forKeyPathDescription: String(describing: comparator.keyPath)
            ) else { return }
            librarySortField = field
            librarySortDirection = LibrarySortDirection(sortOrder: comparator.order)
        }
    }

    @ViewBuilder
    private func tableCell(for column: MediaListColumn, row: MediaTableRow) -> some View {
        #if os(macOS)
        let isBulkSelected = isBulkEditMode && bulkSelection.contains(row.id)
        let isDragPreviewed = isBulkEditMode && bulkSelection.isDragPreviewed(row.id)

        tableCellContent(for: column, row: row)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(isBulkSelected ? Color.white : Color.primary)
            .background {
                TableRowSelectionBackground(isSelected: isBulkSelected, isDragPreviewed: isDragPreviewed)
            }
            .modifier(
                MediaTableCellAccessibility(
                    column: column,
                    rowIndex: row.index,
                    isSelected: isBulkSelected
                )
            )
        #else
        tableCellContent(for: column, row: row)
        #endif
    }

    @ViewBuilder
    private func tableCellContent(for column: MediaListColumn, row: MediaTableRow) -> some View {
        switch column {
        case .index:
            Text("\(row.index)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .artwork:
            LibraryItemArtworkView(item: row.item)
        case .title:
            HStack(spacing: 6) {
                if differentiateWithoutColor, isBulkEditMode, bulkSelection.contains(row.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .accessibilityHidden(true)
                }
                if player.currentItem?.id == row.id {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                }
                Text(row.item.title)
            }
            .lineLimit(1)
            .contextMenu {
                rowMenu(for: row.item)
            }
        case .artist:
            Text(row.item.displayArtist)
                .lineLimit(1)
        case .album:
            Text(row.item.displayAlbum)
                .lineLimit(1)
        case .genre:
            Text(row.item.displayGenre)
                .lineLimit(1)
        case .duration:
            Text(row.item.duration.mediaTime)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .trackNumber:
            Text(metadataText(row.item.trackNumber))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .year:
            Text(metadataText(row.item.year))
                .lineLimit(1)
        case .albumArtist:
            Text(metadataText(row.item.albumArtist))
                .lineLimit(1)
        case .composer:
            Text(metadataText(row.item.composer))
                .lineLimit(1)
        case .discNumber:
            Text(metadataText(row.item.discNumber))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .kind:
            Text(row.item.isVideo ? L10n.string("Video") : L10n.string("Audio"))
                .lineLimit(1)
        case .contentType:
            Text(row.item.displayContentType)
                .lineLimit(1)
        case .dateAdded:
            Text(row.item.addedAt.formatted(date: .numeric, time: .omitted))
                .lineLimit(1)
        case .fileName:
            Text(row.item.fileName)
                .lineLimit(1)
        }
    }

    #if !os(macOS)
    private func mobileTableHeader(columns: [MediaListColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                mobileTableHeaderCell(for: column)
            }
        }
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private func mobileTableHeaderCell(for column: MediaListColumn) -> some View {
        if activePlaylist == nil, let field = LibrarySortField(column: column) {
            Button {
                toggleSort(field)
            } label: {
                HStack(spacing: 4) {
                    Text(column.settingsTitle)
                    if librarySortField == field {
                        Image(systemName: librarySortDirection.icon)
                            .imageScale(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: alignment(for: column))
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: mobileWidth(for: column), alignment: alignment(for: column))
            .padding(.horizontal, 6)
        } else {
            Text(column.settingsTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: mobileWidth(for: column), alignment: alignment(for: column))
                .padding(.horizontal, 6)
        }
    }

    private func mobileTableRow(_ row: MediaTableRow, columns: [MediaListColumn]) -> some View {
        let isSelected = isBulkEditMode ? bulkSelection.contains(row.id) : row.id == selectedItemID

        return HStack(spacing: 0) {
            if isBulkEditMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 34)
            }

            ForEach(columns) { column in
                tableCell(for: column, row: row)
                    .font(.body)
                    .frame(width: mobileWidth(for: column), alignment: alignment(for: column))
                    .padding(.horizontal, 6)
            }
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .contextMenu {
            if isBulkEditMode == false {
                rowMenu(for: row.item)
            }
        }
        .onTapGesture {
            if isBulkEditMode {
                toggleBulkSelection(for: row.item)
            } else {
                play(row.item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction {
            if isBulkEditMode {
                toggleBulkSelection(for: row.item)
            } else {
                play(row.item)
            }
        }
    }

    private func mobileTableWidth(for columns: [MediaListColumn]) -> CGFloat {
        columns.reduce(CGFloat.zero) { width, column in
            width + mobileWidth(for: column) + 12
        }
    }

    private func mobileWidth(for column: MediaListColumn) -> CGFloat {
        switch column {
        case .index: 40
        case .artwork: 46
        case .duration: 70
        case .trackNumber, .year, .discNumber, .kind, .contentType: 82
        case .genre: 110
        case .dateAdded: 120
        case .title: 220
        case .artist, .album, .albumArtist, .composer, .fileName: 160
        }
    }

    private func alignment(for column: MediaListColumn) -> Alignment {
        switch column {
        case .index, .duration, .trackNumber, .discNumber:
            .trailing
        case .artwork:
            .center
        default:
            .leading
        }
    }
    #endif

    private var groupedList: some View {
        List(selection: tableInteractionSelection) {
            ForEach(groupedSections) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        groupedRow(row)
                            .tag(row.id)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var rows: [MediaTableRow] {
        items.enumerated().map { offset, item in
            MediaTableRow(index: offset + 1, item: item)
        }
    }

    private var selectedInfoCommandAction: MediaInfoCommandAction? {
        guard isBulkEditMode == false, selectedItem != nil else { return nil }
        return MediaInfoCommandAction {
            showInfoForSelectedItem()
        }
    }

    private var selectedAACVersionCommandAction: AACVersionCommandAction? {
        guard isBulkEditMode == false,
              let selectedItem,
              selectedItem.isVideo == false,
              canCreateAACVersion
        else { return nil }

        return AACVersionCommandAction {
            createAACVersion(selectedItem)
        }
    }

    private var tableInteractionSelection: Binding<Set<UUID>> {
        Binding {
            if isBulkEditMode {
                return []
            }
            return selectedItemID.map { Set([$0]) } ?? []
        } set: { newSelection in
            guard isBulkEditMode == false else { return }
            selectedItemID = newSelection.first
        }
    }

    private var selectedItem: MediaItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            activePlaylist == nil ? L10n.string("No Media") : L10n.string("Playlist is Empty"),
            systemImage: activePlaylist == nil ? "tray.and.arrow.down" : "music.note.list",
            description: Text(
                activePlaylist == nil
                    ? L10n.string("Import files or drag and drop them here.")
                    : L10n.string("Use the toolbar add button or a track menu to add items.")
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupedSections: [GroupedMediaSection] {
        let groupedRows = Dictionary(grouping: rows) { row in
            groupTitle(for: row.item)
        }

        return groupedRows.keys.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        .map { title in
            GroupedMediaSection(
                title: title,
                rows: groupedRows[title] ?? []
            )
        }
    }

    private func groupedRow(_ row: MediaTableRow) -> some View {
        let isBulkSelected = isBulkEditMode && bulkSelection.contains(row.id)

        return HStack(spacing: 10) {
            if differentiateWithoutColor, isBulkSelected {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityHidden(true)
            }
            Text("\(row.index)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            LibraryItemArtworkView(item: row.item)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if player.currentItem?.id == row.id {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.secondary)
                    }
                    Text(row.item.title)
                        .lineLimit(1)
                }

                Text(secondaryText(for: row.item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(row.item.duration.mediaTime)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .foregroundStyle(isBulkSelected ? Color.white : Color.primary)
        .background(isBulkSelected ? bulkSelectionColor : Color.clear)
        .contextMenu {
            if isBulkEditMode == false {
                rowMenu(for: row.item)
            }
        }
        .onTapGesture {
            if isBulkEditMode {
                toggleBulkSelection(for: row.item)
            } else {
                selectedItemID = row.id
            }
        }
        .onTapGesture(count: 2) {
            if isBulkEditMode == false {
                play(row.item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isBulkSelected ? .isSelected : [])
        .accessibilityAction {
            if isBulkEditMode {
                toggleBulkSelection(for: row.item)
            } else {
                selectedItemID = row.id
            }
        }
    }

    @ViewBuilder
    private func rowMenu(for item: MediaItem) -> some View {
        Button {
            infoItem = item
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }

        Divider()

        Button {
            createAACVersion(item)
        } label: {
            Label("Create AAC Version", systemImage: "waveform.badge.plus")
        }
        .disabled(item.isVideo || canCreateAACVersion == false)

        Divider()

        if activePlaylist != nil {
            Button {
                movePlaylistItem(item, -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(canMove(item, by: -1) == false)

            Button {
                movePlaylistItem(item, 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(canMove(item, by: 1) == false)

            Button {
                removeFromPlaylist(item)
            } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }

            Divider()
        }

        Menu {
            Button {
                createPlaylistWithItem(item)
            } label: {
                Label("New Playlist", systemImage: "plus")
            }

            if playlists.isEmpty == false {
                Divider()
            }

            ForEach(playlists) { playlist in
                Button {
                    addToPlaylist(item, playlist)
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
                .disabled(playlist.contains(item))
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Divider()

        Button(role: .destructive) {
            deleteConfirmationItem = item
        } label: {
            Label("Delete from Library", systemImage: "trash")
        }
    }

    private func item(in selection: Set<UUID>) -> MediaItem? {
        guard let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    private func showInfoForSelectedItem() {
        guard isBulkEditMode == false else { return }
        guard let selectedItem else { return }
        infoItem = selectedItem
    }

    private func playSelection(_ selection: Set<UUID>) {
        guard let item = item(in: selection) else { return }
        play(item)
    }

    private func play(_ item: MediaItem) {
        guard isBulkEditMode == false else { return }
        selectedItemID = item.id
        player.play(item: item, in: queue)
    }

    private func toggleBulkSelection(for item: MediaItem) {
        bulkSelection.toggle(item.id)
    }

    private var bulkSelectionColor: Color {
        #if os(macOS)
        Color(nsColor: .selectedContentBackgroundColor)
        #else
        Color.accentColor
        #endif
    }

    private func syncSelectionToCurrentItem() {
        guard isBulkEditMode == false else { return }
        guard let id = player.currentItem?.id, items.contains(where: { $0.id == id }) else {
            selectedItemID = nil
            return
        }
        selectedItemID = id
    }

    private func groupTitle(for item: MediaItem) -> String {
        guard let section else { return "" }
        return switch section {
        case .albums:
            normalizedMetadata(item.displayAlbum, fallback: L10n.string("Unknown Album"))
        case .artists:
            normalizedMetadata(item.displayArtist, fallback: L10n.string("Unknown Artist"))
        case .genres:
            normalizedMetadata(item.displayGenre, fallback: L10n.string("No Genre"))
        case .allSongs, .allVideos:
            ""
        }
    }

    private func secondaryText(for item: MediaItem) -> String {
        guard let section else { return item.artist }
        return switch section {
        case .albums:
            item.displayArtist
        case .artists:
            item.displayAlbum
        case .genres:
            "\(item.displayArtist) - \(item.displayAlbum)"
        case .allSongs, .allVideos:
            item.displayArtist
        }
    }

    private func normalizedMetadata(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func metadataText(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "-" : trimmed
    }

    private func canMove(_ item: MediaItem, by offset: Int) -> Bool {
        guard activePlaylist != nil, let index = items.firstIndex(where: { $0.id == item.id }) else {
            return false
        }
        return items.indices.contains(index + offset)
    }

    private func toggleSort(_ field: LibrarySortField) {
        guard activePlaylist == nil else { return }
        if librarySortField == field {
            librarySortDirection = librarySortDirection == .ascending ? .descending : .ascending
        } else {
            librarySortField = field
            librarySortDirection = .ascending
        }
    }
}

private struct AlbumBrowserView<ItemMenu: View>: View {
    let items: [MediaItem]
    let player: PlayerViewModel
    @Binding var selectedItemID: UUID?
    @Binding var isBulkEditMode: Bool
    let bulkSelection: BulkMediaSelectionState
    let itemMenu: (MediaItem) -> ItemMenu

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var artworkTransition
    @State private var selectedAlbumID: String?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20, alignment: .top)
    ]

    var body: some View {
        Group {
            if let selectedAlbum {
                albumDetail(selectedAlbum)
            } else {
                albumGrid
            }
        }
        .onChange(of: albums.map(\.id)) { _, albumIDs in
            if let selectedAlbumID, albumIDs.contains(selectedAlbumID) == false {
                self.selectedAlbumID = nil
            }
        }
    }

    private var albums: [LibraryAlbum] {
        LibraryAlbum.grouped(items)
    }

    private var selectedAlbum: LibraryAlbum? {
        guard let selectedAlbumID else { return nil }
        return albums.first { $0.id == selectedAlbumID }
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 24) {
                ForEach(albums) { album in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                            selectedAlbumID = album.id
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            AlbumArtworkView(artworkID: album.artworkID)
                                .matchedGeometryEffect(id: album.id, in: artworkTransition)

                            Text(album.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            Text(album.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(album.title), \(album.artist)")
                }
            }
            .padding(24)
        }
        .background(.background)
    }

    private func albumDetail(_ album: LibraryAlbum) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                        selectedAlbumID = nil
                    }
                } label: {
                    Label("Back to List", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

                albumHeader(album)
                    .padding(.bottom, 24)

                Divider()

                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { offset, item in
                    albumTrackRow(item, fallbackNumber: offset + 1, tracks: album.tracks)

                    if offset < album.tracks.count - 1 {
                        Divider()
                            .padding(.leading, 50)
                    }
                }
            }
            .padding(24)
        }
        .background(.background)
    }

    @ViewBuilder
    private func albumHeader(_ album: LibraryAlbum) -> some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: 20) {
                albumArtwork(album)
                    .frame(maxWidth: 260)
                albumInformation(album)
            }
        } else {
            HStack(alignment: .bottom, spacing: 30) {
                albumArtwork(album)
                    .frame(width: 240, height: 240)
                albumInformation(album)
                    .padding(.bottom, 4)
                Spacer(minLength: 0)
            }
        }
    }

    private func albumArtwork(_ album: LibraryAlbum) -> some View {
        AlbumArtworkView(artworkID: album.artworkID)
            .matchedGeometryEffect(id: album.id, in: artworkTransition)
    }

    private func albumInformation(_ album: LibraryAlbum) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(album.title)
                .font(.largeTitle.bold())
                .textSelection(.enabled)

            Text(album.artist)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .textSelection(.enabled)

            if album.metadataSummary.isEmpty == false {
                Text(album.metadataSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(L10n.format("%d songs", album.tracks.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                guard let firstTrack = album.tracks.first else { return }
                play(firstTrack, in: album.tracks)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBulkEditMode)
            .padding(.top, 14)
        }
    }

    private func albumTrackRow(_ item: MediaItem, fallbackNumber: Int, tracks: [MediaItem]) -> some View {
        let isSelected = isBulkEditMode ? bulkSelection.contains(item.id) : selectedItemID == item.id

        return HStack(spacing: 12) {
            if differentiateWithoutColor, isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityHidden(true)
            }
            Text(trackNumber(for: item, fallback: fallbackNumber))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)

            if player.currentItem?.id == item.id {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)

                if item.displayArtist != selectedAlbum?.artist {
                    Text(item.displayArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(item.duration.mediaTime)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .clipShape(.rect(cornerRadius: 6))
        .contextMenu {
            if isBulkEditMode == false {
                itemMenu(item)
            }
        }
        .onTapGesture {
            if isBulkEditMode {
                bulkSelection.toggle(item.id)
            } else {
                selectedItemID = item.id
            }
        }
        .onTapGesture(count: 2) {
            if isBulkEditMode == false {
                play(item, in: tracks)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction {
            if isBulkEditMode {
                bulkSelection.toggle(item.id)
            } else {
                selectedItemID = item.id
            }
        }
    }

    private func play(_ item: MediaItem, in tracks: [MediaItem]) {
        selectedItemID = item.id
        player.play(item: item, in: tracks)
    }

    private func trackNumber(for item: MediaItem, fallback: Int) -> String {
        let value = item.trackNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty == false else { return "\(fallback)" }
        return String(value.split(separator: "/", maxSplits: 1).first ?? Substring(value))
    }
}

private struct LibraryAlbum: Identifiable {
    let id: String
    let title: String
    let artist: String
    let artworkID: UUID?
    let metadataSummary: String
    let tracks: [MediaItem]

    static func grouped(_ items: [MediaItem]) -> [LibraryAlbum] {
        Dictionary(grouping: items, by: \.displayAlbum)
            .map { title, albumItems in
                let tracks = albumItems.sorted(by: trackComesBefore)
                let firstTrack = tracks[0]
                let artist = firstNonBlankAlbumArtist(in: tracks) ?? summarizedArtist(in: tracks)
                let metadataSummary = [firstTrack.year, firstTrack.genre]
                    .compactMap(normalized)
                    .joined(separator: " • ")

                return LibraryAlbum(
                    id: title,
                    title: title,
                    artist: artist,
                    artworkID: tracks.lazy.compactMap(\.artworkID).first,
                    metadataSummary: metadataSummary,
                    tracks: tracks
                )
            }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    private static func firstNonBlankAlbumArtist(in items: [MediaItem]) -> String? {
        items.lazy.compactMap { normalized($0.albumArtist) }.first
    }

    private static func summarizedArtist(in items: [MediaItem]) -> String {
        let artists = items.map(\.displayArtist).reduce(into: [String]()) { result, artist in
            if result.contains(where: { $0.localizedStandardCompare(artist) == .orderedSame }) == false {
                result.append(artist)
            }
        }

        if artists.count == 1 {
            return artists[0]
        }
        return L10n.string("Various Artists")
    }

    private static func trackComesBefore(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        let lhsKey = (metadataNumber(lhs.discNumber), metadataNumber(lhs.trackNumber))
        let rhsKey = (metadataNumber(rhs.discNumber), metadataNumber(rhs.trackNumber))

        if lhsKey.0 != rhsKey.0 { return lhsKey.0 < rhsKey.0 }
        if lhsKey.1 != rhsKey.1 { return lhsKey.1 < rhsKey.1 }

        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func metadataNumber(_ value: String?) -> Int {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = trimmed.prefix { $0.isNumber }
        return Int(prefix) ?? .max
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AlbumArtworkView: View {
    let artworkID: UUID?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            LibraryArtworkView(artworkID: artworkID)
                .font(.system(size: 42, weight: .light))
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }
}

#if os(macOS)
private struct MediaTableCellAccessibility: ViewModifier {
    let column: MediaListColumn
    let rowIndex: Int
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if column == .title {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mediaRow.\(rowIndex)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
        }
    }
}

// SwiftUI Table installs its own selection gestures before cell gestures. Intercept presses
// and drags at the table boundary so the visible and editable bulk selections stay in sync.
private struct TableBulkSelectionInputBridge: NSViewRepresentable {
    let isEnabled: Bool
    let selection: BulkMediaSelectionState
    let rowIDs: [UUID]

    func makeNSView(context: Context) -> TableBulkSelectionInputView {
        TableBulkSelectionInputView(
            isEnabled: isEnabled,
            selection: selection,
            rowIDs: rowIDs
        )
    }

    func updateNSView(_ nsView: TableBulkSelectionInputView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.selection = selection
        nsView.rowIDs = rowIDs
    }
}

final class TableBulkSelectionInputView: NSView {
    private static let dragActivationDistance: CGFloat = 4

    var isEnabled: Bool
    var selection: BulkMediaSelectionState
    var rowIDs: [UUID]
    private var isPassingThroughHitTest = false

    init(
        isEnabled: Bool,
        selection: BulkMediaSelectionState,
        rowIDs: [UUID]
    ) {
        self.isEnabled = isEnabled
        self.selection = selection
        self.rowIDs = rowIDs
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled,
              isPassingThroughHitTest == false,
              bounds.contains(point),
              let window,
              tableRow(at: convert(point, to: nil), in: window) != nil
        else { return nil }
        return self
    }

    @discardableResult
    func toggleRow(at rowIndex: Int) -> Bool {
        guard isEnabled, rowIDs.indices.contains(rowIndex) else { return false }
        selection.toggle(rowIDs[rowIndex])
        return true
    }

    @discardableResult
    func selectRows(from anchorRowIndex: Int, through currentRowIndex: Int) -> Bool {
        guard isEnabled,
              rowIDs.indices.contains(anchorRowIndex),
              rowIDs.indices.contains(currentRowIndex)
        else { return false }

        let lowerBound = min(anchorRowIndex, currentRowIndex)
        let upperBound = max(anchorRowIndex, currentRowIndex)
        selection.select(rowIDs[lowerBound...upperBound])
        return true
    }

    @discardableResult
    func previewRows(from anchorRowIndex: Int, through currentRowIndex: Int) -> Bool {
        guard isEnabled,
              rowIDs.indices.contains(anchorRowIndex),
              rowIDs.indices.contains(currentRowIndex)
        else { return false }

        let lowerBound = min(anchorRowIndex, currentRowIndex)
        let upperBound = max(anchorRowIndex, currentRowIndex)
        selection.updateDragPreview(rowIDs[lowerBound...upperBound])
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled,
              event.buttonNumber == 0,
              let window,
              event.window === window,
              let (tableView, rowIndex) = tableRow(
                at: event.locationInWindow,
                in: window
              )
        else { return }

        let gesture = trackSelectionGesture(
            from: rowIndex,
            initialLocation: event.locationInWindow,
            in: tableView,
            window: window
        )
        selection.clearDragPreview()

        guard let gesture else {
            tableView.deselectAll(nil)
            return
        }

        if gesture.didDrag {
            _ = selectRows(from: rowIndex, through: gesture.currentRowIndex)
        } else {
            _ = toggleRow(at: rowIndex)
        }

        tableView.deselectAll(nil)
    }

    private func trackSelectionGesture(
        from anchorRowIndex: Int,
        initialLocation: NSPoint,
        in tableView: NSTableView,
        window: NSWindow
    ) -> (currentRowIndex: Int, didDrag: Bool)? {
        var currentRowIndex = anchorRowIndex
        var didDrag = false
        var didComplete = false

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }

            switch event.type {
            case .leftMouseDragged:
                guard didDrag || hasExceededDragThreshold(
                    at: event.locationInWindow,
                    from: initialLocation
                ) else { break }

                didDrag = true
                if let rowIndex = trackedRowIndex(for: event, in: tableView) {
                    currentRowIndex = rowIndex
                }
                previewRows(from: anchorRowIndex, through: currentRowIndex)
            case .leftMouseUp:
                if didDrag == false {
                    didDrag = hasExceededDragThreshold(
                        at: event.locationInWindow,
                        from: initialLocation
                    )
                }
                if didDrag,
                   let rowIndex = trackedRowIndex(for: event, in: tableView) {
                    currentRowIndex = rowIndex
                }
                didComplete = true
                stop.pointee = true
            default:
                break
            }
        }

        guard didComplete else { return nil }
        return (currentRowIndex, didDrag)
    }

    private func hasExceededDragThreshold(at location: NSPoint, from initialLocation: NSPoint) -> Bool {
        let horizontalDistance = location.x - initialLocation.x
        let verticalDistance = location.y - initialLocation.y
        let distanceSquared = horizontalDistance * horizontalDistance
            + verticalDistance * verticalDistance
        let thresholdSquared = Self.dragActivationDistance * Self.dragActivationDistance
        return distanceSquared >= thresholdSquared
    }

    private func trackedRowIndex(for event: NSEvent, in tableView: NSTableView) -> Int? {
        let tablePoint = tableView.convert(event.locationInWindow, from: nil)
        let rowIndex = tableView.row(at: tablePoint)
        return rowIDs.indices.contains(rowIndex) ? rowIndex : nil
    }

    private func tableRow(
        at location: NSPoint,
        in window: NSWindow
    ) -> (tableView: NSTableView, rowIndex: Int)? {
        isPassingThroughHitTest = true
        defer { isPassingThroughHitTest = false }

        var currentView = window.contentView?.hitTest(location)
        while let view = currentView {
            if let tableView = view as? NSTableView {
                let tablePoint = tableView.convert(location, from: nil)
                let rowIndex = tableView.row(at: tablePoint)
                guard rowIDs.indices.contains(rowIndex) else { return nil }
                return (tableView, rowIndex)
            }
            currentView = view.superview
        }
        return nil
    }
}

@MainActor
enum RapidBulkSelectionUITestDriver {
    static let rowIndices = [7, 10, 3, 4, 8, 1, 6, 9]
    static let clickIntervalMilliseconds = 250
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing-multiple-selection")
        #else
        false
        #endif
    }

    static func selectRows(
        selection: BulkMediaSelectionState,
        rowIDs: [UUID],
        completion: @escaping @MainActor (TimeInterval) -> Void
    ) {
        guard isEnabled else { return }

        Task { @MainActor in
            let clock = ContinuousClock()
            let startedAt = clock.now
            let startedDate = Date()

            for (offset, rowIndex) in rowIndices.enumerated() {
                if offset > 0 {
                    let deadline = startedAt.advanced(
                        by: .milliseconds(clickIntervalMilliseconds * offset)
                    )
                    try? await clock.sleep(until: deadline)
                }

                guard rowIDs.indices.contains(rowIndex - 1) else { return }
                selection.toggle(rowIDs[rowIndex - 1])
            }

            completion(Date().timeIntervalSince(startedDate))
        }
    }
}

// SwiftUI Table exposes cell content but not row backgrounds, so bridge to the enclosing AppKit row.
private struct TableRowSelectionBackground: NSViewRepresentable {
    let isSelected: Bool
    var isDragPreviewed: Bool = false

    func makeNSView(context: Context) -> TableRowSelectionBackgroundView {
        TableRowSelectionBackgroundView(isSelected: isSelected, isDragPreviewed: isDragPreviewed)
    }

    func updateNSView(_ nsView: TableRowSelectionBackgroundView, context: Context) {
        nsView.isSelected = isSelected
        nsView.isDragPreviewed = isDragPreviewed
    }

    static func dismantleNSView(_ nsView: TableRowSelectionBackgroundView, coordinator: ()) {
        nsView.detachFromRow()
    }
}

final class TableRowSelectionBackgroundView: NSView {
    static let dragPreviewRowBackgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3)

    var isSelected: Bool {
        didSet {
            updateRowBackground()
        }
    }

    var isDragPreviewed: Bool {
        didSet {
            updateRowBackground()
        }
    }

    private weak var rowView: NSTableRowView?

    init(isSelected: Bool, isDragPreviewed: Bool = false) {
        self.isSelected = isSelected
        self.isDragPreviewed = isDragPreviewed
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateRowBackground()
    }

    override func layout() {
        super.layout()
        updateRowBackground()
    }

    func detachFromRow() {
        guard let previousRowView = rowView else { return }
        isSelected = false
        isDragPreviewed = false
        rowView = nil
        refreshBackground(of: previousRowView, excluding: self)
    }

    private func updateRowBackground() {
        guard let currentRowView = enclosingRowView() else { return }

        if rowView !== currentRowView {
            if let previousRowView = rowView {
                refreshBackground(of: previousRowView, excluding: self)
            }
            rowView = currentRowView
        }

        refreshBackground(of: currentRowView)
    }

    private func refreshBackground(
        of rowView: NSTableRowView,
        excluding excludedView: TableRowSelectionBackgroundView? = nil
    ) {
        let highlight = highlightState(in: rowView, excluding: excludedView)
        if highlight.isSelected {
            rowView.backgroundColor = .selectedContentBackgroundColor
        } else if highlight.isDragPreviewed {
            rowView.backgroundColor = Self.dragPreviewRowBackgroundColor
        } else {
            rowView.backgroundColor = unselectedBackgroundColor(for: rowView)
        }
    }

    private func unselectedBackgroundColor(for rowView: NSTableRowView) -> NSColor {
        guard let tableView = enclosingTableView(from: rowView),
              tableView.usesAlternatingRowBackgroundColors else {
            return .clear
        }

        return AlternatingTableRowBackground.color(
            rowIndex: tableView.row(for: rowView),
            colors: NSColor.alternatingContentBackgroundColors
        )
    }

    private func highlightState(
        in view: NSView,
        excluding excludedView: TableRowSelectionBackgroundView?
    ) -> (isSelected: Bool, isDragPreviewed: Bool) {
        var isSelected = false
        var isDragPreviewed = false
        collectHighlightState(
            in: view,
            excluding: excludedView,
            isSelected: &isSelected,
            isDragPreviewed: &isDragPreviewed
        )
        return (isSelected, isDragPreviewed)
    }

    private func collectHighlightState(
        in view: NSView,
        excluding excludedView: TableRowSelectionBackgroundView?,
        isSelected: inout Bool,
        isDragPreviewed: inout Bool
    ) {
        for subview in view.subviews {
            if let backgroundView = subview as? TableRowSelectionBackgroundView,
               backgroundView !== excludedView {
                isSelected = isSelected || backgroundView.isSelected
                isDragPreviewed = isDragPreviewed || backgroundView.isDragPreviewed
            }
            if isSelected {
                return
            }
            collectHighlightState(
                in: subview,
                excluding: excludedView,
                isSelected: &isSelected,
                isDragPreviewed: &isDragPreviewed
            )
        }
    }

    private func enclosingRowView() -> NSTableRowView? {
        var ancestor = superview
        while let view = ancestor {
            if let rowView = view as? NSTableRowView {
                return rowView
            }
            ancestor = view.superview
        }
        return nil
    }

    private func enclosingTableView(from rowView: NSTableRowView) -> NSTableView? {
        var ancestor = rowView.superview
        while let view = ancestor {
            if let tableView = view as? NSTableView {
                return tableView
            }
            ancestor = view.superview
        }
        return nil
    }
}

enum AlternatingTableRowBackground {
    static func color(rowIndex: Int, colors: [NSColor]) -> NSColor {
        guard rowIndex >= 0, colors.isEmpty == false else { return .clear }
        return colors[rowIndex % colors.count]
    }
}
#endif

enum BulkMediaSelection {
    nonisolated static func toggling(_ id: UUID, in current: Set<UUID>) -> Set<UUID> {
        var updated = current
        if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }
        return updated
    }
}

@MainActor
@Observable
final class BulkMediaSelectionState {
    private(set) var ids: Set<UUID>
    private(set) var dragPreviewIDs: Set<UUID> = []

    init(ids: Set<UUID> = []) {
        self.ids = ids
    }

    func contains(_ id: UUID) -> Bool {
        ids.contains(id)
    }

    func isDragPreviewed(_ id: UUID) -> Bool {
        dragPreviewIDs.contains(id)
    }

    func toggle(_ id: UUID) {
        ids = BulkMediaSelection.toggling(id, in: ids)
    }

    func select<S: Sequence>(_ newIDs: S) where S.Element == UUID {
        ids.formUnion(newIDs)
    }

    func updateDragPreview<S: Sequence>(_ newIDs: S) where S.Element == UUID {
        dragPreviewIDs = Set(newIDs)
    }

    func clearDragPreview() {
        dragPreviewIDs.removeAll()
    }

    func retain(ids validIDs: Set<UUID>) {
        ids.formIntersection(validIDs)
    }

    func reset() {
        ids.removeAll()
        dragPreviewIDs.removeAll()
    }
}

struct MediaTableRow: Identifiable, @unchecked Sendable {
    let index: Int
    let item: MediaItem
    let indexSortValue: Int
    let artworkSortValue: String
    let titleSortValue: String
    let artistSortValue: String
    let albumSortValue: String
    let genreSortValue: String
    let durationSortValue: TimeInterval
    let trackNumberSortValue: String
    let yearSortValue: String
    let albumArtistSortValue: String
    let composerSortValue: String
    let discNumberSortValue: String
    let kindSortValue: String
    let contentTypeSortValue: String
    let dateAddedSortValue: Date
    let fileNameSortValue: String

    init(index: Int, item: MediaItem) {
        self.index = index
        self.item = item
        indexSortValue = index
        artworkSortValue = item.hasArtwork ? "1" : ""
        titleSortValue = item.title
        artistSortValue = item.displayArtist
        albumSortValue = item.displayAlbum
        genreSortValue = item.displayGenre
        durationSortValue = item.duration
        trackNumberSortValue = item.trackNumber ?? ""
        yearSortValue = item.year ?? ""
        albumArtistSortValue = item.albumArtist ?? ""
        composerSortValue = item.composer ?? ""
        discNumberSortValue = item.discNumber ?? ""
        kindSortValue = item.isVideo ? L10n.string("Video") : L10n.string("Audio")
        contentTypeSortValue = item.displayContentType
        dateAddedSortValue = item.addedAt
        fileNameSortValue = item.fileName
    }

    var id: UUID {
        item.id
    }

    static func sortField(forKeyPathDescription keyPathDescription: String) -> LibrarySortField? {
        if keyPathDescription.hasSuffix(".indexSortValue") { return .dateAdded }
        if keyPathDescription.hasSuffix(".artworkSortValue") { return .title }
        if keyPathDescription.hasSuffix(".dateAddedSortValue") { return .dateAdded }
        if keyPathDescription.hasSuffix(".titleSortValue") { return .title }
        if keyPathDescription.hasSuffix(".artistSortValue") { return .artist }
        if keyPathDescription.hasSuffix(".albumSortValue") { return .album }
        if keyPathDescription.hasSuffix(".genreSortValue") { return .genre }
        if keyPathDescription.hasSuffix(".durationSortValue") { return .duration }
        if keyPathDescription.hasSuffix(".trackNumberSortValue") { return .trackNumber }
        if keyPathDescription.hasSuffix(".yearSortValue") { return .year }
        if keyPathDescription.hasSuffix(".albumArtistSortValue") { return .albumArtist }
        if keyPathDescription.hasSuffix(".composerSortValue") { return .composer }
        if keyPathDescription.hasSuffix(".discNumberSortValue") { return .discNumber }
        if keyPathDescription.hasSuffix(".kindSortValue") { return .kind }
        if keyPathDescription.hasSuffix(".contentTypeSortValue") { return .contentType }
        if keyPathDescription.hasSuffix(".fileNameSortValue") { return .fileName }
        return nil
    }
}

private struct GroupedMediaSection: Identifiable {
    let title: String
    let rows: [MediaTableRow]

    var id: String {
        title
    }
}

struct BulkMetadataEditView: View {
    let items: [MediaItem]
    let libraryService: LibraryService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "")
    @State private var appliedFields: Set<MediaMetadataEditField> = []
    @State private var editableItemIDs: Set<UUID> = []
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
            editableItemIDs = Set(items.filter { libraryService.canEditEmbeddedMetadata(for: $0) }.map(\.id))
        }
        .onDisappear {
            artworkLoadRequestID = nil
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
            .disabled(isSaving || editableItems.isEmpty)
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
            if editableItems.isEmpty, appliedFields.contains(.artwork) == false {
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

    private func bulkEditableRow(field: MediaMetadataEditField, label: String, text: Binding<String>) -> some View {
        GridRow {
            Toggle(label, isOn: fieldBinding(field))
                .labelsHidden()
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

    private func bulkEditableNumberPairRow(
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

    private func bulkEditableToggleRow(field: MediaMetadataEditField, label: String, isOn: Binding<Bool>) -> some View {
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

    private func fieldBinding(_ field: MediaMetadataEditField) -> Binding<Bool> {
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

    private func numberPairComponent(_ component: NumberPairComponent, in text: Binding<String>) -> Binding<String> {
        Binding {
            NumberPairParts(text.wrappedValue)[component]
        } set: { newValue in
            var parts = NumberPairParts(text.wrappedValue)
            parts[component] = newValue.filter(\.isNumber)
            text.wrappedValue = parts.combinedValue
            clearResult()
        }
    }

    private var patch: MediaMetadataEditPatch {
        MediaMetadataEditPatch(fields: appliedFields, draft: draft)
    }

    private var editableItems: [MediaItem] {
        items.filter { editableItemIDs.contains($0.id) }
    }

    private var targetItems: [MediaItem] {
        appliedFields.contains(.artwork) ? items : editableItems
    }

    private var unsupportedCount: Int {
        max(items.count - editableItems.count, 0)
    }

    private var selectionSummary: String {
        if editableItems.count == items.count || appliedFields.contains(.artwork) {
            return L10n.format("%d selected", items.count)
        }
        return L10n.format("%d selected, %d editable", items.count, editableItems.count)
    }

    private var canApply: Bool {
        isSaving == false && patch.isEmpty == false && targetItems.isEmpty == false
    }

    private func clearResult() {
        result = nil
    }

    private func close() {
        if isSaving == false, patch.isEmpty == false {
            isDiscardChangesConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private func save() {
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
            .frame(minHeight: 420)

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

    private func editableToggleRow(label: String, isOn: Binding<Bool>) -> some View {
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

    private func numberPairComponent(_ component: NumberPairComponent, in text: Binding<String>) -> Binding<String> {
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

    private func numberPairParts(_ value: String) -> NumberPairParts {
        NumberPairParts(value)
    }

    private var canSaveMetadata: Bool {
        isSavingMetadata == false
            && metadataDraftItemID == item.id
            && hasUnsavedMetadataChanges
            && (canEditEmbeddedMetadata || metadataDraft.editsArtwork)
    }

    private var hasUnsavedMetadataChanges: Bool {
        metadataDraft != originalMetadataDraft
    }

    private func close() {
        if isSavingMetadata == false, hasUnsavedMetadataChanges {
            isDiscardChangesConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private func infoSection(title: String, rows: [MediaInfoRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(rows) { row in
                    infoRow(row)
                }
            }
        }
    }

    private func infoRow(_ row: MediaInfoRow) -> some View {
        GridRow {
            Text(row.label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            Text(row.value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        canEditEmbeddedMetadata = libraryService.canEditEmbeddedMetadata(for: item)
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
        let draft = metadataDraft
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

private enum NumberPairComponent {
    case current
    case total
}

private struct NumberPairParts {
    var current: String
    var total: String

    init(_ value: String) {
        let pieces = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        current = pieces.first.map(String.init) ?? ""
        total = pieces.dropFirst().first.map(String.init) ?? ""
    }

    subscript(component: NumberPairComponent) -> String {
        get {
            switch component {
            case .current:
                current
            case .total:
                total
            }
        }
        set {
            switch component {
            case .current:
                current = newValue
            case .total:
                total = newValue
            }
        }
    }

    var combinedValue: String {
        if current.isEmpty, total.isEmpty {
            return ""
        }
        if total.isEmpty {
            return current
        }
        return "\(current)/\(total)"
    }
}

private extension LibrarySection {
    var isGrouped: Bool {
        switch self {
        case .albums, .artists, .genres:
            true
        case .allSongs, .allVideos:
            false
        }
    }
}

struct ArtworkView: View {
    let data: Data?
    let isVideo: Bool
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let data, let image = platformImage(data: data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: isVideo ? "film" : "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 3))
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
}

extension TimeInterval {
    var mediaTime: String {
        guard isFinite else { return "00:00" }
        let value = max(0, Int(self))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

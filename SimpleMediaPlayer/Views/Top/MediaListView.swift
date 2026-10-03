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

private struct GroupedMediaSection: Identifiable {
    let title: String
    let rows: [MediaTableRow]

    var id: String {
        title
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

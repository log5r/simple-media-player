import SwiftUI

extension MediaListView {
    @ViewBuilder
    var mediaTable: some View {
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
        let tableRows = rows
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(tableRows) { row in
                        mobileTableRow(row, columns: visibleMediaListColumns)
                            .id(row.id)
                            .modifier(LibraryScrollAnchorRow(id: row.id))
                    }
                } header: {
                    mobileTableHeader(columns: visibleMediaListColumns)
                }
            }
            .frame(minWidth: mobileTableWidth(for: visibleMediaListColumns), alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading)
        .background(.background)
        .modifier(LibraryScrollAnchor(itemIDs: tableRows.map(\.id), browsingState: browsingState))
        #endif
    }

    var visibleMediaListColumns: [MediaListColumn] {
        MediaListColumn.visibleColumns(
            orderRawValue: columnOrderRaw,
            visibleRawValue: visibleColumnsRaw
        )
    }

    var tableSortOrderBinding: Binding<[KeyPathComparator<MediaTableRow>]> {
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
    func tableCell(for column: MediaListColumn, row: MediaTableRow) -> some View {
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
    func tableCellContent(for column: MediaListColumn, row: MediaTableRow) -> some View {
        switch column {
        case .index:
            Text("\(row.index)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .artwork:
            LibraryItemArtworkView(item: row.item)
        case .title:
            tableTitle(row)
        case .duration:
            Text(row.item.duration.mediaTime)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .trackNumber, .discNumber:
            Text(tableTextValue(for: column, item: row.item))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        default:
            Text(tableTextValue(for: column, item: row.item)).lineLimit(1)
        }
    }

    private func tableTitle(_ row: MediaTableRow) -> some View {
        HStack(spacing: 6) {
            if differentiateWithoutColor, isBulkEditMode, bulkSelection.contains(row.id) {
                Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
            }
            if player.currentItem?.id == row.id {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
            }
            Text(row.item.title)
        }
        .lineLimit(1)
        .contextMenu { rowMenu(for: row.item) }
    }

    private func tableTextValue(for column: MediaListColumn, item: MediaItem) -> String {
        switch column {
        case .artist: item.displayArtist
        case .album: item.displayAlbum
        case .genre: item.displayGenre
        case .dateAdded: item.addedAt.formatted(date: .numeric, time: .omitted)
        case .fileName: item.fileName
        case .contentType: item.displayContentType
        case .kind:
            if item.isVideo { L10n.string("Video") } else { L10n.string("Audio") }
        default: metadataText(tableMetadataValue(for: column, item: item))
        }
    }

    private func tableMetadataValue(for column: MediaListColumn, item: MediaItem) -> String? {
        switch column {
        case .trackNumber: item.trackNumber
        case .discNumber: item.discNumber
        case .year: item.year
        case .albumArtist: item.albumArtist
        case .composer: item.composer
        default: nil
        }
    }
}

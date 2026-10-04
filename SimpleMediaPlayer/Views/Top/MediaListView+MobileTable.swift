import SwiftUI

extension MediaListView {
    #if !os(macOS)
    func mobileTableHeader(columns: [MediaListColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                mobileTableHeaderCell(for: column)
            }
        }
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    func mobileTableHeaderCell(for column: MediaListColumn) -> some View {
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
                .frame(maxWidth: .infinity, minHeight: 44, alignment: alignment(for: column))
                .contentShape(Rectangle())
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

    func mobileTableRow(_ row: MediaTableRow, columns: [MediaListColumn]) -> some View {
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
        .accessibilityIdentifier("libraryTrack.\(row.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction {
            if isBulkEditMode {
                toggleBulkSelection(for: row.item)
            } else {
                play(row.item)
            }
        }
    }

    func mobileTableWidth(for columns: [MediaListColumn]) -> CGFloat {
        columns.reduce(CGFloat.zero) { width, column in
            width + mobileWidth(for: column) + 12
        }
    }

    func mobileWidth(for column: MediaListColumn) -> CGFloat {
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

    func alignment(for column: MediaListColumn) -> Alignment {
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

}

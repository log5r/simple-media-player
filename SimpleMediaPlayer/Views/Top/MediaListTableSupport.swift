import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

#if os(macOS)
// SwiftUI Table exposes cell content but not row backgrounds, so bridge to the enclosing AppKit row.
struct TableRowSelectionBackground: NSViewRepresentable {
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

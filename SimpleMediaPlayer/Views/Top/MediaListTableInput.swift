import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct MediaTableCellAccessibility: ViewModifier {
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
struct TableBulkSelectionInputBridge: NSViewRepresentable {
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
#endif

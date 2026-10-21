import SwiftUI

nonisolated private struct LibraryRowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct LibraryScrollAnchorRow: ViewModifier {
    let id: UUID

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: LibraryRowFrames.self,
                    value: [id: geometry.frame(in: .named("libraryTrackScroll"))]
                )
            }
        }
    }
}

/// Save a visible item, rather than a pixel offset whose meaning changes with row layout.
/// Projection replacement may briefly be empty; restore only after its first populated result.
struct LibraryScrollAnchor: ViewModifier {
    let itemIDs: [UUID]
    let browsingState: LibraryBrowsingState
    /// The height of a header pinned over the rows, which must equal the row height.
    /// `scrollTo` aligns a row with the viewport top, beneath that header.
    var pinnedHeaderHeight: CGFloat = 0
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var hasRestored = false
    @State private var destination: Destination?
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .scrollPosition($position)
                .coordinateSpace(name: "libraryTrackScroll")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                .onPreferenceChange(LibraryRowFrames.self) { rowFrames = $0 }
                .onChange(of: Destination(browsingState)) { _, _ in
                    hasRestored = false
                    destination = nil
                    rowFrames = [:]
                    restoreScrollPosition(using: proxy)
                }
                .onChange(of: itemIDs, initial: true) { _, _ in
                    restoreScrollPosition(using: proxy)
                }
                .onScrollPhaseChange { _, phase in
                    guard phase == .idle, hasRestored, destination == Destination(browsingState) else { return }
                    let bounds = pinnedHeaderHeight..<viewportHeight
                    if let first = Self.firstVisibleItemID(in: rowFrames, within: bounds) {
                        browsingState.scrollItemID = first
                    }
                }
        }
    }

    /// The topmost row with any part inside the vertical `bounds` of the viewport.
    static func firstVisibleItemID(in rowFrames: [UUID: CGRect], within bounds: Range<CGFloat>) -> UUID? {
        rowFrames
            .filter { $0.value.maxY > bounds.lowerBound && $0.value.minY < bounds.upperBound }
            .min { $0.value.minY < $1.value.minY }?
            .key
    }

    private func restoreScrollPosition(using proxy: ScrollViewProxy) {
        guard hasRestored == false, itemIDs.isEmpty == false else { return }
        hasRestored = true
        destination = Destination(browsingState)
        let index = browsingState.scrollItemID.flatMap(itemIDs.firstIndex(of:)) ?? 0
        // `scrollTo` would hide what precedes the first row, such as an album header or a pinned section header.
        guard index > 0 else {
            position.scrollTo(x: 0, y: 0)
            return
        }
        // The previous row goes under the one-row header, leaving the saved row just below it.
        proxy.scrollTo(itemIDs[pinnedHeaderHeight > 0 ? index - 1 : index], anchor: .topLeading)
    }

    private struct Destination: Equatable {
        let selection: SidebarSelection
        let group: LibraryBrowsingGroup?
        let tab: Int

        init(_ state: LibraryBrowsingState) {
            selection = state.selection
            group = state.group
            tab = state.phoneTab
        }
    }
}

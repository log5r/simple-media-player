import SwiftUI

nonisolated private struct LibraryRowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

nonisolated private struct LibrarySectionHeaderFrames: PreferenceKey {
    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
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

/// Marks a section header that hides rows when pinned, for `LibraryScrollAnchor.coversRowsUnderTopInset`.
struct LibraryScrollAnchorSectionHeader: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: LibrarySectionHeaderFrames.self,
                    value: [geometry.frame(in: .named("libraryTrackScroll"))]
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
    /// Whether rows scroll under the top content inset, such as a navigation bar, and under section headers
    /// pinned there, as in a `List`. Only saving needs them; `List.scrollTo` restores a row below its header.
    var coversRowsUnderTopInset = false
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var topInset: CGFloat = 0
    @State private var sectionHeaderFrames: [CGRect] = []
    @State private var hasRestored = false
    @State private var destination: Destination?
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .scrollPosition($position)
                .coordinateSpace(name: "libraryTrackScroll")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, top in
                    topInset = top
                }
                .onPreferenceChange(LibraryRowFrames.self) { rowFrames = $0 }
                .onPreferenceChange(LibrarySectionHeaderFrames.self) { sectionHeaderFrames = $0 }
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
                    let top = coversRowsUnderTopInset
                        ? Self.visibleTop(belowInset: topInset, sectionHeaders: sectionHeaderFrames)
                        : pinnedHeaderHeight
                    let first = Self.firstVisibleItemID(in: rowFrames, from: top, to: viewportHeight)
                    if let first {
                        browsingState.scrollItemID = first
                    }
                }
        }
    }

    /// The topmost row with any part between `top` and `bottom` of the viewport.
    /// An empty or inverted interval, such as a viewport shorter than the header, has no visible row.
    static func firstVisibleItemID(in rowFrames: [UUID: CGRect], from top: CGFloat, to bottom: CGFloat) -> UUID? {
        guard bottom > top else { return nil }
        return rowFrames
            .filter { $0.value.maxY > top && $0.value.minY < bottom }
            .min { $0.value.minY < $1.value.minY }?
            .key
    }

    /// The top of the rows left visible by the top inset and the section headers pinned at it.
    /// A pinned header's content sits below the inset by its cell padding, which is less than its own height.
    static func visibleTop(belowInset inset: CGFloat, sectionHeaders: [CGRect]) -> CGFloat {
        sectionHeaders
            .filter { $0.minY < inset + $0.height && $0.maxY > inset }
            .map(\.maxY)
            .max() ?? inset
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

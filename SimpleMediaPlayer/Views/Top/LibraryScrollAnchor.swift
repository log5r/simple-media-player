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
            positioned(content)
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
                    let first = Self.firstVisibleItemID(in: rowFrames, from: pinnedHeaderHeight, to: viewportHeight)
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

    @ViewBuilder
    private func positioned(_ content: Content) -> some View {
        if pinnedHeaderHeight > 0 {
            content.scrollPosition($position)
        } else {
            content
        }
    }

    private func restoreScrollPosition(using proxy: ScrollViewProxy) {
        guard hasRestored == false, let first = itemIDs.first else { return }
        hasRestored = true
        destination = Destination(browsingState)
        let saved = browsingState.scrollItemID.flatMap { itemIDs.contains($0) ? $0 : nil }
        guard pinnedHeaderHeight > 0 else {
            proxy.scrollTo(saved ?? first, anchor: .topLeading)
            return
        }
        // The previous row goes under the one-row header, leaving the saved row just below it.
        if let index = saved.flatMap(itemIDs.firstIndex(of:)), index > 0 {
            proxy.scrollTo(itemIDs[index - 1], anchor: .topLeading)
        } else {
            position.scrollTo(x: 0, y: 0)
        }
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

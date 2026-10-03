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
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var hasRestored = false
    @State private var destination: Destination?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
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
                    let visible = rowFrames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }
                    if let first = visible.min(by: { $0.value.minY < $1.value.minY }) {
                        browsingState.scrollItemID = first.key
                    }
                }
        }
    }

    private func restoreScrollPosition(using proxy: ScrollViewProxy) {
        guard hasRestored == false, let first = itemIDs.first else { return }
        hasRestored = true
        destination = Destination(browsingState)
        let saved = browsingState.scrollItemID.flatMap { itemIDs.contains($0) ? $0 : nil }
        proxy.scrollTo(saved ?? first, anchor: .topLeading)
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

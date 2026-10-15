#if os(iOS)
import SwiftUI

extension MainView {
    /// `portraitLibraryTop` places the open Library below the fold, like a sheet over the player's controls.
    @ViewBuilder
    func expandedIOSView(size: CGSize, portraitPlayer: Bool, portraitLibraryTop: CGFloat?) -> some View {
        if portraitPlayer {
            // Keep one structure so the Library keeps its state when the fold or the keyboard moves it.
            ZStack(alignment: .top) {
                if !showsPortraitLibrary || portraitLibraryTop != nil {
                    DuoPortraitPlayerView(
                        player: player, selectedItem: selectedItem, queue: browsingPlaybackQueue,
                        playItem: playBrowsingItem, requestSaveCopy: { saveCopyTarget = $0 },
                        showLibrary: { showsPortraitLibrary = true },
                        showSettings: { browsingState.showsSettings = true },
                        showEqualizer: { browsingState.showsEqualizer = true },
                        showDetails: { browsingState.showsDetails = true },
                        showVideoFullScreen: { browsingState.showsVideoFullScreen = true },
                        showsControls: !showsPortraitLibrary
                    )
                }
                if showsPortraitLibrary {
                    portraitLibrary(isBelowFold: portraitLibraryTop != nil)
                        .padding(.top, portraitLibraryTop ?? 0)
                }
            }
        } else {
            desktopView(availableWidth: size.width)
                // Own floating search at the screen level so the playback panel doesn't clip it.
                .searchable(text: $browsingState.searchText, placement: .toolbar, prompt: "Search")
        }
    }

    private func portraitLibrary(isBelowFold: Bool) -> some View {
        let cornerRadius: CGFloat = isBelowFold ? 16 : 0
        return VStack(spacing: 0) {
            libraryNavigation(searchesInDetail: true)
            Button { showsPortraitLibrary = false } label: {
                Label("Close", systemImage: "chevron.down")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityIdentifier("duoCloseLibrary")
                .padding(8)
        }
        .clipShape(PortraitLibraryShape(cornerRadius: cornerRadius))
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius, style: .continuous
            )
            .fill(Color(uiColor: .systemBackground))
            .shadow(color: .black.opacity(isBelowFold ? 0.25 : 0), radius: 12, y: -2)
            .ignoresSafeArea(edges: .bottom)
        }
        #if DEBUG
        .modifier(DuoPanelRegionDiagnostics(regionID: "duoPortraitLibrary"))
        #endif
    }
}

/// Round only the top corners below the fold; the full-screen Library keeps its backgrounds under the status bar.
nonisolated private struct PortraitLibraryShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard cornerRadius > 0 else { return Path(rect.insetBy(dx: -rect.width, dy: -rect.height)) }
        return UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius, style: .continuous
        ).path(in: rect)
    }
}
#endif

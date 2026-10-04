#if os(iOS)
import SwiftUI

extension MainView {
    @ViewBuilder
    func expandedIOSView(size: CGSize, portraitPlayer: Bool) -> some View {
        if portraitPlayer {
            Group {
                if showsPortraitLibrary {
                    VStack(spacing: 0) {
                        libraryNavigation
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
                } else {
                    DuoPortraitPlayerView(
                        player: player, selectedItem: selectedItem, queue: browsingPlaybackQueue,
                        playItem: playBrowsingItem, requestSaveCopy: { saveCopyTarget = $0 },
                        showLibrary: { showsPortraitLibrary = true },
                        showSettings: { browsingState.showsSettings = true },
                        showEqualizer: { browsingState.showsEqualizer = true },
                        showDetails: { browsingState.showsDetails = true },
                        showVideoFullScreen: { browsingState.showsVideoFullScreen = true }
                    )
                }
            }
        } else {
            desktopView(availableWidth: size.width)
        }
    }
}
#endif

#if os(iOS)
import SwiftUI

/// The tab accessory supplies its material and shape; keep its content within the compact row.
struct IPhoneLEDDock: View {
    let player: PlayerViewModel
    let openDeck: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 12) {
            IPhoneNowPlayingButton(player: player, openDeck: openDeck, showsTime: placement != .inline)

            playbackButton(
                player.isPlaying ? "Pause" : "Play",
                symbol: player.isPlaying ? "pause.fill" : "play.fill", identifier: "phoneDockPlayPause"
            ) { player.togglePlayPause() }
            if placement != .inline {
                playbackButton("Next Track", symbol: "forward.end.fill", identifier: "phoneDockNext") {
                    player.next()
                }.disabled(!player.canSkipToNext)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func playbackButton(
        _ title: LocalizedStringKey, symbol: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private struct IPhoneNowPlayingButton: View {
    let player: PlayerViewModel
    let openDeck: () -> Void
    let showsTime: Bool

    var body: some View {
        let time = TimeInterval(player.elapsedSeconds).mediaTime
        Button(action: openDeck) {
            ViewThatFits(in: .vertical) {
                if showsTime {
                    VStack(alignment: .leading, spacing: 2) {
                        trackTitle
                        Text(time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                trackTitle
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Now Playing")
        .accessibilityValue(
            (player.currentItem?.title ?? "") + ", " + L10n.format("Playback time %@", time)
        )
        .accessibilityHint("Open the playback deck")
        .accessibilityIdentifier("phoneLEDDock")
    }

    private var trackTitle: some View {
        Text(player.currentItem?.title ?? L10n.string("No Track"))
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
    }

}
#endif

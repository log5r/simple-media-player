import SwiftUI

struct PhoneLEDContent: View {
    let player: PlayerViewModel
    let palette: LEDDisplayPalette
    let mediaInfoStyle: MediaInfoDisplayStyle
    let layout: LEDDisplayLayout
    let visualizerHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: layout == .phoneDeck ? 8 : 3) {
            if layout == .phoneDeck {
                HStack {
                    Text(trackNumber)
                    Spacer()
                    Text(player.currentItem?.displayContentType ?? "")
                }
                .font(.custom("Dotrice-Regular", size: 14))
            }
            MarqueeText(
                text: player.currentItem?.title ?? L10n.string("No Track"),
                font: mediaInfoStyle.titleFont(scale: layout == .phoneDeck ? 1.6 : 1),
                tracking: mediaInfoStyle.textTracking, color: palette.primaryColor,
                shadowOpacity: palette.textShadowOpacity, shadowRadius: palette.textShadowRadius
            )
            .frame(height: layout == .phoneDeck ? 30 : 18)
            if layout == .phoneDeck {
                MarqueeText(
                    text: subtitle, font: mediaInfoStyle.subtitleFont(scale: 1.2),
                    color: palette.primaryColor, shadowOpacity: palette.textShadowOpacity,
                    shadowRadius: palette.textShadowRadius
                )
                .frame(height: 20)
            }
            HStack(spacing: 8) {
                SevenSegmentTimeView(
                    time: player.currentTime, color: palette.primaryColor,
                    scale: layout == .phoneDeck ? 1.5 : 0.7,
                    shadowOpacity: palette.timeShadowOpacity, shadowRadius: palette.timeShadowRadius
                )
                Spacer(minLength: 0)
                if layout == .phoneDeck {
                    AuxiliaryLEDColumns(player: player, palette: palette, informationScale: 1)
                } else {
                    if player.isVideoMode == false && player.pitchSemitones != 0 {
                        Text("KEY " + PitchSpeedTextFormatter.pitch(player.pitchSemitones))
                            .font(.custom("Dotrice-Regular", size: 9))
                    }
                }
            }
            if layout == .phoneDeck {
                Spacer(minLength: 0)
                MusicAnalysisStripView(player: player, palette: palette, mediaInfoStyle: mediaInfoStyle)
                VisualizerHostView(player: player, palette: palette).frame(height: visualizerHeight)
            } else {
                GeometryReader { proxy in
                    Rectangle().fill(palette.primaryColor.opacity(0.2))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(palette.primaryColor)
                                .frame(width: proxy.size.width * playbackFraction)
                        }
                }.frame(height: 2).accessibilityHidden(true)
            }
        }
        .foregroundStyle(palette.primaryColor)
    }

    private var trackNumber: String {
        if let number = player.currentItem?.trackNumber, !number.isEmpty { return number }
        return player.queue.firstIndex { $0.id == player.currentItem?.id }.map { String($0 + 1) } ?? "—"
    }

    private var playbackFraction: Double {
        min(max(player.currentTime / max(player.duration, 1), 0), 1)
    }

    private var subtitle: String {
        guard let item = player.currentItem, !item.isVideo else { return "" }
        return "\(item.displayArtist) - \(item.displayAlbum)"
    }
}

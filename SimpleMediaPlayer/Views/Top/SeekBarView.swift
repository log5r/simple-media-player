import SwiftUI

struct SeekBarView: View {
    let player: PlayerViewModel
    @State private var dragValue: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            Text(displayTime.mediaTime)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(max(displayTime, sliderRange.lowerBound), sliderRange.upperBound) },
                    set: { dragValue = $0 }
                ),
                in: sliderRange,
                onEditingChanged: { editing in
                    guard editing == false else { return }
                    if let dragValue {
                        player.seek(to: dragValue)
                    }
                    dragValue = nil
                }
            )
            .disabled(player.currentItem == nil)
            .accessibilityLabel(L10n.string("Playback Position"))
            .accessibilityValue(
                L10n.format(
                    "%@ of %@",
                    displayTime.mediaTime,
                    player.duration.mediaTime
                )
            )

            Text("-" + max(0, player.duration - displayTime).mediaTime)
                .frame(width: 54, alignment: .leading)
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(player.currentItem == nil ? .secondary : .primary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }

    private var displayTime: TimeInterval {
        dragValue ?? player.currentTime
    }

    private var sliderRange: ClosedRange<Double> {
        0...max(player.duration, 0.001)
    }
}

import SwiftUI

struct SeekBarView: View {
    let player: PlayerViewModel
    @State private var dragValue: TimeInterval?
    @State private var dragTarget: PlaybackSeekTarget?
    @State private var isDragging = false
    @State private var isVisible = true

    var body: some View {
        Group {
            #if os(iOS)
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let safeFrames = DeckSafeRegions.frames(
                    in: bounds, avoiding: DeckReservedRegions.activeFrames(in: proxy)
                )
                let safeFrame = safeFrames
                    .max { $0.width * $0.height < $1.width * $1.height } ?? .zero
                seekControls
                    .frame(width: safeFrame.width, height: safeFrame.height)
                    .contentShape(Rectangle())
                    .clipped()
                    .offset(x: safeFrame.minX, y: safeFrame.minY)
            }
            #else
            seekControls
            #endif
        }
        .frame(height: seekHeight)
        .background(.bar)
        .onChange(of: player.playbackGeneration) { _, _ in dragValue = nil }
        .onChange(of: player.currentItem?.id) { _, _ in dragValue = nil }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            dragValue = nil
            dragTarget = nil
            isDragging = false
        }
    }

    private var seekControls: some View {
        HStack(spacing: 10) {
            Text(displayTime.mediaTime)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(max(displayTime, sliderRange.lowerBound), sliderRange.upperBound) },
                    set: { value in
                        guard isVisible else { return }
                        if isDragging {
                            dragValue = value
                        } else if player.currentItem != nil {
                            player.seek(to: value)
                        }
                    }
                ),
                in: sliderRange,
                onEditingChanged: { editing in
                    guard isVisible else { return }
                    if editing {
                        isDragging = true
                        dragTarget = PlaybackSeekTarget(
                            itemID: player.currentItem?.id, generation: player.playbackGeneration
                        )
                        return
                    }
                    if let dragValue, dragTarget?.isValid(
                        itemID: player.currentItem?.id, generation: player.playbackGeneration
                    ) == true {
                        player.seek(to: dragValue)
                    }
                    dragValue = nil
                    dragTarget = nil
                    isDragging = false
                }
            )
            .frame(minHeight: seekHeight)
            .contentShape(Rectangle())
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
    }

    private var displayTime: TimeInterval {
        dragValue ?? player.currentTime
    }

    private var sliderRange: ClosedRange<Double> {
        0...max(player.duration, 0.001)
    }

    private var seekHeight: CGFloat {
        #if os(iOS)
        44
        #else
        30
        #endif
    }
}

struct PlaybackSeekTarget: Equatable {
    let itemID: UUID?
    let generation: UInt64

    func isValid(itemID currentItemID: UUID?, generation currentGeneration: UInt64) -> Bool {
        itemID != nil && itemID == currentItemID && generation == currentGeneration
    }
}

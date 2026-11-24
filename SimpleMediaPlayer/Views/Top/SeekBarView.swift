import SwiftUI

struct SeekBarView: View {
    let player: PlayerViewModel
    var avoidsDisplayDivision = true
    /// The phone deck draws the seek row directly on its panel and aligns the times to its content column.
    var drawsOnPanel = false
    /// Height-constrained deck pages can opt out of the extra row for Dynamic Type.
    var stacksTimesAtAccessibilitySizes = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var timesHeight: CGFloat = 0
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
                    in: bounds, avoiding: DeckReservedRegions.activeFrames(
                        in: proxy, includesDivisions: avoidsDisplayDivision
                    )
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
        .frame(height: seekHeight + (stacksTimes ? timesHeight : 0))
        .background(drawsOnPanel ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
        .onChange(of: player.playbackGeneration) { _, _ in dragValue = nil }
        .onChange(of: player.currentItem?.id) { _, _ in dragValue = nil }
        // Switching layouts rebuilds the slider, so a drag in progress cannot report its end.
        .onChange(of: stacksTimes) { _, _ in
            dragValue = nil
            dragTarget = nil
            isDragging = false
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            dragValue = nil
            dragTarget = nil
            isDragging = false
        }
    }

    private var seekControls: some View {
        Group {
            if stacksTimes {
                stackedSeekControls
            } else {
                inlineSeekControls
            }
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(player.currentItem == nil ? .secondary : .primary)
        .padding(.horizontal, drawsOnPanel ? 0 : 14)
    }

    private var inlineSeekControls: some View {
        HStack(spacing: 10) {
            elapsedTime
                .frame(width: 48, alignment: drawsOnPanel ? .leading : .trailing)
            slider
            remainingTime
                .frame(width: 54, alignment: drawsOnPanel ? .trailing : .leading)
        }
    }

    /// The slider keeps its full-width row, and the times sit below it at their full size.
    private var stackedSeekControls: some View {
        VStack(spacing: 0) {
            slider
                .frame(height: seekHeight)
            // Times too wide to share a line put the remaining time on its own line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    elapsedTime.fixedSize()
                    Spacer(minLength: 0)
                    remainingTime.fixedSize()
                }
                VStack(spacing: 0) {
                    elapsedTime.fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    remainingTime.fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // Whole points keep the rows below on whole-point positions.
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { timesHeight = $0 }
        }
    }

    private var elapsedTime: some View {
        Text(displayTime.mediaTime)
            .accessibilityIdentifier("seekElapsedTime")
    }

    private var remainingTime: some View {
        Text("-" + max(0, player.duration - displayTime).mediaTime)
            .accessibilityIdentifier("seekRemainingTime")
    }

    private var slider: some View {
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
    }

    private var stacksTimes: Bool {
        #if os(iOS)
        stacksTimesAtAccessibilitySizes && dynamicTypeSize.isAccessibilitySize
        #else
        false
        #endif
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

import SwiftUI

struct VolumeSlotView: View {
    let value: Double
    let palette: BottomPanelPalette
    var axis: Axis = .vertical
    /// The phone deck has no room for a number beside the slot, so it shows the level only while dragging.
    var showsValueWhileDragging = false
    let onChange: (Double) -> Void
    @GestureState private var isDragging = false

    private let ribHeight: CGFloat = 2
    private let ribSpacing: CGFloat = 1.5
    private let innerPadding: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let length = axis == .vertical ? proxy.size.height : proxy.size.width
            let innerLength = max(1, length - innerPadding * 2)
            let ribCount = max(1, Int((innerLength + ribSpacing) / (ribHeight + ribSpacing)))
            let filledCount = Int((value * Double(ribCount)).rounded())

            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.volumeSlotFill)

                let layout = axis == .vertical
                    ? AnyLayout(VStackLayout(spacing: ribSpacing))
                    : AnyLayout(HStackLayout(spacing: ribSpacing))
                layout {
                    ForEach(0..<ribCount, id: \.self) { index in
                        let isFilled = axis == .vertical ? index >= ribCount - filledCount : index < filledCount
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(isFilled
                                  ? AnyShapeStyle(palette.volumeFilledRib) : AnyShapeStyle(palette.volumeEmptyRib))
                            .frame(width: axis == .horizontal ? ribHeight : nil,
                                   height: axis == .vertical ? ribHeight : nil)
                    }
                }
                .padding(innerPadding)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(palette.volumeSlotStroke, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.volumeSlotBottomHighlight)
                    .frame(height: 1)
                    .offset(y: 1)
            }
            .overlay {
                if showsValueWhileDragging && isDragging {
                    Text(verbatim: "\(Int(value * 100))")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(palette.labelColor)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 22)
                        .background(palette.normalButtonFill, in: RoundedRectangle(cornerRadius: 3))
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { gesture in
                        let position = axis == .vertical ? gesture.location.y : gesture.location.x
                        let fraction = Double(min(max(position - innerPadding, 0), innerLength) / innerLength)
                        onChange(axis == .vertical ? 1 - fraction : fraction)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("volumeLevel")
        .accessibilityLabel("Volume")
        .accessibilityValue(L10n.format("%d percent", Int(value * 100)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(value + 0.1)
            case .decrement: onChange(value - 0.1)
            @unknown default: break
            }
        }
        .help("Volume")
    }
}

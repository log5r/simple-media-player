#if os(iOS)
import AVKit
import SwiftUI

extension View {
    /// The shared control shape: the macOS bottom panel's 3 pt corner, outline, and shadow.
    /// The outline stays inside the frame so adjacent rows and their touch targets keep exact 44 pt edges.
    func iPhoneDeckControlFrame(_ palette: BottomPanelPalette) -> some View {
        clipShape(RoundedRectangle(cornerRadius: IPhoneDeckLayout.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: IPhoneDeckLayout.controlCornerRadius)
                    .strokeBorder(palette.controlStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: palette.buttonShadow, radius: 2, y: 1)
    }
}

/// Divides the row's width by weight, so cells stretch to the content column instead of centering.
struct IPhoneDeckCellRow: Layout {
    var weights: [CGFloat] = []
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width }
            + spacing * CGFloat(max(0, subviews.count - 1))
        let widths = cellWidths(totalWidth: width, count: subviews.count)
        let height = zip(subviews, widths).reduce(CGFloat(0)) { height, pair in
            max(height, pair.0.sizeThatFits(ProposedViewSize(width: pair.1, height: proposal.height)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var originX = bounds.minX
        for (subview, width) in zip(subviews, cellWidths(totalWidth: bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: originX, y: bounds.minY),
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            originX += width + spacing
        }
    }

    private func cellWidths(totalWidth: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let cellWeights = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let available = max(0, totalWidth - spacing * CGFloat(count - 1))
        let total = cellWeights.reduce(0, +)
        return cellWeights.map { available * $0 / max(total, 1) }
    }
}

/// One cell of a divided bar. A selected cell uses the panel's lit button fill.
struct IPhoneDeckBarCell<Label: View>: View {
    var isSelected = false
    var showsDivider = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let palette = BottomPanelPalette(colorScheme: colorScheme)
        Button(action: action) {
            label()
                .foregroundStyle(foreground(palette))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    Rectangle().fill(
                        isSelected ? AnyShapeStyle(palette.activeButtonFill) : AnyShapeStyle(palette.normalButtonFill)
                    )
                }
                .overlay(alignment: .leading) {
                    if showsDivider { Rectangle().fill(palette.buttonDivider).frame(width: 1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func foreground(_ palette: BottomPanelPalette) -> Color {
        guard isEnabled else { return palette.disabledIcon }
        return isSelected ? palette.activeIcon : palette.enabledIcon
    }
}

/// Stop, Previous, Play/Pause, and Next as one bar; Play/Pause is emphasized by width and symbol size.
struct IPhoneTransportBar: View {
    let player: PlayerViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        IPhoneDeckCellRow(weights: [1, 1, 2, 1]) {
            cell("Stop", symbol: "stop.fill", identifier: "phoneStop", showsDivider: false) { player.stop() }
            cell("Previous Track", symbol: "backward.end.fill", identifier: "phonePrevious") { player.previous() }
                .disabled(!player.canPlayPrevious)
            cell(
                player.canPause ? "Pause" : "Play", symbol: player.canPause ? "pause.fill" : "play.fill",
                identifier: "phonePlayPause", symbolSize: 24
            ) { player.togglePlayPause() }
            cell("Next Track", symbol: "forward.end.fill", identifier: "phoneNext") { player.next() }
                .disabled(!player.canSkipToNext)
        }
        .frame(height: IPhoneDeckLayout.rowHeight)
        .iPhoneDeckControlFrame(BottomPanelPalette(colorScheme: colorScheme))
    }

    private func cell(
        _ title: String, symbol: String, identifier: String, symbolSize: CGFloat = 18, showsDivider: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        IPhoneDeckBarCell(showsDivider: showsDivider, action: action) {
            Image(systemName: symbol).font(.system(size: symbolSize, weight: .semibold))
        }
        .accessibilityLabel(L10n.string(String.LocalizationValue(title))).accessibilityIdentifier(identifier)
    }
}

struct IPhoneTransportButton: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let palette = BottomPanelPalette(colorScheme: colorScheme)
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isEnabled ? palette.enabledIcon : palette.disabledIcon)
                .frame(width: IPhoneDeckLayout.rowHeight, height: IPhoneDeckLayout.rowHeight)
                .background(palette.normalButtonFill)
                .iPhoneDeckControlFrame(palette)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(String.LocalizationValue(title))).accessibilityIdentifier(identifier)
    }
}

/// AirPlay in the same 44 pt square as Mute, tinted with the panel's icon colors instead of the accent color.
struct IPhoneRouteButton: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = BottomPanelPalette(colorScheme: colorScheme)
        IPhoneRoutePicker(tintColor: UIColor(palette.enabledIcon), activeTintColor: UIColor(palette.activeIcon))
            .frame(width: IPhoneDeckLayout.rowHeight, height: IPhoneDeckLayout.rowHeight)
            .background(palette.normalButtonFill)
            .iPhoneDeckControlFrame(palette)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phoneRoutePicker")
    }
}

struct IPhoneRoutePicker: UIViewRepresentable {
    let tintColor: UIColor
    let activeTintColor: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.accessibilityLabel = L10n.string("Output Device")
        view.accessibilityIdentifier = "phoneRoutePicker"
        view.prioritizesVideoDevices = false
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}
#endif

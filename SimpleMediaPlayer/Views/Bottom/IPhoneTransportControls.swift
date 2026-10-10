#if os(iOS)
import AVKit
import SwiftUI

struct IPhoneTransportButton: View {
    let title: String
    let symbol: String
    let identifier: String
    var size: CGFloat = 44
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let palette = BottomPanelPalette(colorScheme: colorScheme)
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size > 52 ? 28 : 18, weight: .semibold))
                .foregroundStyle(isEnabled ? palette.enabledIcon : palette.disabledIcon)
                .frame(width: size, height: size)
                .background(palette.normalButtonFill, in: Circle())
                .overlay(Circle().stroke(palette.controlStroke, lineWidth: 1))
                .shadow(color: palette.buttonShadow, radius: 2, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(String.LocalizationValue(title))).accessibilityIdentifier(identifier)
    }
}

struct IPhoneRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.accessibilityLabel = L10n.string("Output Device")
        view.accessibilityIdentifier = "phoneRoutePicker"
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

/// Dockのアイコンを、実行中だけLED表示の配色に合わせて差し替える。
///
/// Finder や Launchpad のアイコンはバンドル同梱のものが使われ、ここでは変化しない。
@MainActor
enum DockIcon {
    private static let canvasSize: CGFloat = 1024
    private static var appliedSignature: String?

    static func apply(palette: LEDDisplayPalette, isEnabled: Bool) {
        guard isEnabled else {
            reset()
            return
        }

        let signature = signature(for: palette)
        guard signature != appliedSignature else { return }

        let renderer = ImageRenderer(content: artwork(for: palette))
        renderer.scale = 1
        guard let image = renderer.nsImage else { return }

        NSApplication.shared.applicationIconImage = image
        appliedSignature = signature
    }

    /// バンドル同梱のアイコンに戻す。
    static func reset() {
        guard appliedSignature != nil else { return }
        NSApplication.shared.applicationIconImage = nil
        appliedSignature = nil
    }

    static func artwork(for palette: LEDDisplayPalette) -> AppIconArtwork {
        switch palette.style {
        case .dark:
            AppIconArtwork(
                face: rgb(palette.foreground),
                mark: rgb(palette.foreground),
                mode: .luminous,
                size: canvasSize
            )
        case .backlit:
            AppIconArtwork(
                face: rgb(palette.backlight),
                mark: rgb(palette.foreground),
                mode: .backlit,
                size: canvasSize
            )
        }
    }

    private static func rgb(_ value: LEDColorValue) -> AppIconArtwork.RGB {
        AppIconArtwork.RGB(red: value.red, green: value.green, blue: value.blue)
    }

    private static func signature(for palette: LEDDisplayPalette) -> String {
        let foreground = palette.foreground
        let backlight = palette.backlight
        return [
            palette.style.rawValue,
            "\(foreground.red),\(foreground.green),\(foreground.blue)",
            "\(backlight.red),\(backlight.green),\(backlight.blue)"
        ].joined(separator: "|")
    }
}

private struct DockIconSyncModifier: ViewModifier {
    @AppStorage(AppSettingsKey.dockIconFollowsLEDColor)
    private var dockIconFollowsLEDColor = AppSettingsDefault.dockIconFollowsLEDColor
    @AppStorage(AppSettingsKey.ledColorHex) private var ledColorHex = AppSettingsDefault.ledColorHex
    @AppStorage(AppSettingsKey.ledBacklitForegroundColorHex)
    private var ledBacklitForegroundColorHex = AppSettingsDefault.ledBacklitForegroundColorHex
    @AppStorage(AppSettingsKey.ledBacklightColorHex)
    private var ledBacklightColorHex = AppSettingsDefault.ledBacklightColorHex
    @AppStorage(AppSettingsKey.ledDisplayStyle) private var ledDisplayStyleRaw = AppSettingsDefault.ledDisplayStyle

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: signature) { _, _ in apply() }
    }

    private var signature: String {
        [
            String(dockIconFollowsLEDColor),
            ledDisplayStyleRaw,
            ledColorHex,
            ledBacklitForegroundColorHex,
            ledBacklightColorHex
        ].joined(separator: "|")
    }

    private func apply() {
        DockIcon.apply(
            palette: LEDDisplayPalette.resolved(
                styleRaw: ledDisplayStyleRaw,
                darkForegroundHex: ledColorHex,
                backlitForegroundHex: ledBacklitForegroundColorHex,
                backlightHex: ledBacklightColorHex
            ),
            isEnabled: dockIconFollowsLEDColor
        )
    }
}

extension View {
    /// LED配色に追従するDockアイコンの更新を、このビューの寿命に紐づける。
    func syncsDockIcon() -> some View {
        modifier(DockIconSyncModifier())
    }
}
#endif

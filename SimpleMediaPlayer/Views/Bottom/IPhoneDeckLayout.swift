import CoreGraphics

enum IPhoneDeckLayout {
    static let spacing: CGFloat = 18
    static let bottomPadding: CGFloat = 12
    static let displayBezelHeight: CGFloat = 10

    /// Side bars can leave a compact portrait deck too short for its full display and playback controls.
    static func displayHeight(
        availableSize: CGSize, controlsHeight: CGFloat, horizontalSafeArea: CGFloat, accessibilityText: Bool
    ) -> CGFloat {
        guard availableSize.height > availableSize.width, horizontalSafeArea > 0,
              !accessibilityText, controlsHeight > 0 else { return 300 }
        let remaining = availableSize.height - controlsHeight - spacing - bottomPadding - displayBezelHeight
        return min(300, max(90, remaining))
    }
}

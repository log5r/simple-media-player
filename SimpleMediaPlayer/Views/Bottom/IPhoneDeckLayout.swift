import CoreGraphics

enum IPhoneDeckLayout {
    static let spacing: CGFloat = 18
    static let bottomPadding: CGFloat = 12
    static let displayBezelHeight: CGFloat = 10
    static let compactSpacing: CGFloat = 8
    static let compactBottomPadding: CGFloat = 8
    static let compactControlsSpacing: CGFloat = 6
    static let minimumSpectrumDisplayHeight: CGFloat = 254

    /// Use the regular controls' height so measuring their compact replacement cannot change this decision.
    static func usesCompactControls(
        availableSize: CGSize, horizontalSafeArea: CGFloat, accessibilityText: Bool
    ) -> Bool {
        let regularControlsHeight: CGFloat = 44 + 54 + 76 + 44 + 3 * spacing
        let fullDeckHeight = 300 + displayBezelHeight + spacing + regularControlsHeight + bottomPadding
        return availableSize.height > availableSize.width && availableSize.height < fullDeckHeight
            && horizontalSafeArea > 0 && !accessibilityText
    }

    /// Side bars can leave a compact portrait deck too short for its full display and playback controls.
    static func displayHeight(
        availableSize: CGSize, controlsHeight: CGFloat, horizontalSafeArea: CGFloat, accessibilityText: Bool
    ) -> CGFloat {
        guard usesCompactControls(availableSize: availableSize, horizontalSafeArea: horizontalSafeArea,
                                  accessibilityText: accessibilityText), controlsHeight > 0 else { return 300 }
        let remaining = availableSize.height - controlsHeight - compactSpacing
            - compactBottomPadding - displayBezelHeight
        return min(300, max(minimumSpectrumDisplayHeight, remaining))
    }

    static func visualizerHeight(displayHeight: CGFloat, compactControls: Bool) -> CGFloat {
        // The full phone display needs about 202 pt for its text, clock, analysis, padding, and gaps.
        // Leave another 8 pt so the compact spectrum stays inside the LED instead of being clipped.
        compactControls ? min(88, max(44, displayHeight - 210)) : min(88, max(20, displayHeight - 180))
    }
}

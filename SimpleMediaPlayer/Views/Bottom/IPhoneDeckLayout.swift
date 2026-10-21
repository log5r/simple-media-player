import CoreGraphics

/// Shared measurements for the phone deck and the Duo player, so every row uses one content column.
enum IPhoneDeckLayout {
    /// The content column's distance from each edge of the safe area.
    static let gutter: CGFloat = 16
    /// Every control row other than the LED: seek, lamps, transport, volume, and page switcher.
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 8
    /// Between the LED, seek and lamps, transport and volume, and the page switcher.
    static let groupSpacing: CGFloat = 16
    static let controlCornerRadius: CGFloat = 3
    static let displayCornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 10
    static let bottomPadding: CGFloat = 8
    static let displayBezelHeight: CGFloat = 10
    static let regularDisplayHeight: CGFloat = 300
    static let maximumDisplayHeight: CGFloat = 340
    static let minimumSpectrumDisplayHeight: CGFloat = 254
    /// The narrowest column that keeps three lamps, the 1:1:2:1 transport bar, and the volume row usable.
    static let minimumControlsWidth: CGFloat = 316
    static let minimumSideBySideDisplayWidth: CGFloat = 220

    /// Seek and lamps, then transport and volume: four rows, two row gaps, and one group gap.
    static let controlsHeight: CGFloat = 4 * rowHeight + 2 * rowSpacing + groupSpacing

    /// Use the regular display's height so measuring the controls cannot change this decision.
    static func usesCompactDisplay(
        availableSize: CGSize, horizontalSafeArea: CGFloat, accessibilityText: Bool
    ) -> Bool {
        let fullDeckHeight = regularDisplayHeight + displayBezelHeight + groupSpacing + controlsHeight + groupSpacing
        return availableSize.height > availableSize.width && availableSize.height < fullDeckHeight
            && horizontalSafeArea > 0 && !accessibilityText
    }

    /// Give spare height to the LED up to its cap, so no gap remains above the page switcher.
    /// Side bars can leave a compact portrait deck too short for its full display, so it shrinks to the spectrum.
    static func displayHeight(
        availableSize: CGSize, controlsHeight: CGFloat, horizontalSafeArea: CGFloat, accessibilityText: Bool
    ) -> CGFloat {
        guard controlsHeight > 0 else { return regularDisplayHeight }
        let compact = usesCompactDisplay(
            availableSize: availableSize, horizontalSafeArea: horizontalSafeArea, accessibilityText: accessibilityText
        )
        let remaining = availableSize.height - controlsHeight - 2 * groupSpacing - displayBezelHeight
        let minimum = compact ? minimumSpectrumDisplayHeight : regularDisplayHeight
        return min(maximumDisplayHeight, max(minimum, remaining))
    }

    /// The narrowest landscape deck that places the controls beside an LED wide enough for its information.
    static var minimumSideBySideWidth: CGFloat {
        minimumControlsWidth + groupSpacing + minimumSideBySideDisplayWidth + 2 * gutter
    }

    /// A compact landscape deck is too short for the LED above the controls; place them side by side instead.
    static func usesSideBySide(availableSize: CGSize) -> Bool {
        availableSize.width > availableSize.height && availableSize.width >= minimumSideBySideWidth
    }

    static func sideBySideWidths(availableWidth: CGFloat) -> (controls: CGFloat, display: CGFloat) {
        let content = max(0, availableWidth - 2 * gutter - groupSpacing)
        let controls = min(content, max(minimumControlsWidth, content / 2))
        return (controls, content - controls)
    }

    static func sideBySideDisplayHeight(availableHeight: CGFloat) -> CGFloat {
        min(maximumDisplayHeight, max(1, availableHeight - groupSpacing - displayBezelHeight))
    }

    static func visualizerHeight(displayHeight: CGFloat, compactControls: Bool) -> CGFloat {
        // The full phone display needs about 202 pt for its text, clock, analysis, padding, and gaps.
        // Leave another 8 pt so the compact spectrum stays inside the LED instead of being clipped.
        compactControls ? min(88, max(44, displayHeight - 210)) : min(88, max(20, displayHeight - 180))
    }
}

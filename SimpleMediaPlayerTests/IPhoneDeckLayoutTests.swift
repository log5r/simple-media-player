import CoreGraphics
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct IPhoneDeckLayoutTests {
    /// The deck's whole stack: the LED plate, a group gap, the controls, and the gap above the page switcher.
    private func stackHeight(displayHeight: CGFloat, controlsHeight: CGFloat) -> CGFloat {
        displayHeight + IPhoneDeckLayout.displayBezelHeight + IPhoneDeckLayout.groupSpacing
            + controlsHeight + IPhoneDeckLayout.groupSpacing
    }

    @Test func controlRowsShareOneHeightAndSpacing() {
        #expect(IPhoneDeckLayout.rowHeight == 44)
        #expect(IPhoneDeckLayout.rowSpacing == 8)
        #expect(IPhoneDeckLayout.groupSpacing == 16)
        #expect(IPhoneDeckLayout.gutter == 16)
        #expect(IPhoneDeckLayout.controlsHeight == 208)
    }

    @Test func closedDisplayFitsTheControlsAndFullSpectrum() {
        let availableSize = CGSize(width: 382, height: 510)
        #expect(IPhoneDeckLayout.usesCompactDisplay(
            availableSize: availableSize, horizontalSafeArea: 84, accessibilityText: false
        ))
        let height = IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: IPhoneDeckLayout.controlsHeight,
            horizontalSafeArea: 84, accessibilityText: false
        )
        #expect(height == 260)
        #expect(IPhoneDeckLayout.visualizerHeight(displayHeight: height, compactControls: true) == 50)
        #expect(stackHeight(displayHeight: height, controlsHeight: IPhoneDeckLayout.controlsHeight)
            == availableSize.height)
    }

    /// An iPhone 18 Pro deck leaves more height than the LED's cap, so the LED stops at 340 pt.
    @Test(arguments: [CGFloat(600), 672, 800])
    func ordinaryPhonesCapTheDisplayHeight(availableHeight: CGFloat) {
        let availableSize = CGSize(width: 402, height: availableHeight)
        #expect(!IPhoneDeckLayout.usesCompactDisplay(
            availableSize: availableSize, horizontalSafeArea: 0, accessibilityText: false
        ))
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: IPhoneDeckLayout.controlsHeight,
            horizontalSafeArea: 0, accessibilityText: false
        ) == IPhoneDeckLayout.maximumDisplayHeight)
    }

    /// Below the cap, the LED takes the spare height so the volume row sits 16 pt above the page switcher.
    @Test(arguments: [CGFloat(550), 570, 590])
    func ordinaryPhonesGiveSpareHeightToTheDisplay(availableHeight: CGFloat) {
        let availableSize = CGSize(width: 402, height: availableHeight)
        let height = IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: IPhoneDeckLayout.controlsHeight,
            horizontalSafeArea: 0, accessibilityText: false
        )
        #expect(height >= IPhoneDeckLayout.regularDisplayHeight)
        #expect(height <= IPhoneDeckLayout.maximumDisplayHeight)
        #expect(stackHeight(displayHeight: height, controlsHeight: IPhoneDeckLayout.controlsHeight)
            == availableSize.height)
    }

    @Test(arguments: [CGFloat(300), 500])
    func shortOrdinaryPhonesKeepTheRegularDisplayAndScroll(availableHeight: CGFloat) {
        let availableSize = CGSize(width: 375, height: availableHeight)
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: IPhoneDeckLayout.controlsHeight,
            horizontalSafeArea: 0, accessibilityText: false
        ) == IPhoneDeckLayout.regularDisplayHeight)
    }

    @Test func unmeasuredControlsKeepTheRegularDisplay() {
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 402, height: 672), controlsHeight: 0,
            horizontalSafeArea: 0, accessibilityText: false
        ) == IPhoneDeckLayout.regularDisplayHeight)
    }

    @Test func accessibilityTextKeepsTheRegularScrollableDisplay() {
        let availableSize = CGSize(width: 382, height: 510)
        #expect(!IPhoneDeckLayout.usesCompactDisplay(
            availableSize: availableSize, horizontalSafeArea: 84, accessibilityText: true
        ))
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: 400, horizontalSafeArea: 84, accessibilityText: true
        ) == IPhoneDeckLayout.regularDisplayHeight)
    }

    /// The decision uses the fixed row heights: 300 + 10 + 16 + 208 + 16 = 550 pt.
    @Test func compactDisplayChoiceUsesTheStableRegularHeight() {
        #expect(IPhoneDeckLayout.usesCompactDisplay(
            availableSize: CGSize(width: 382, height: 549), horizontalSafeArea: 84, accessibilityText: false
        ))
        #expect(!IPhoneDeckLayout.usesCompactDisplay(
            availableSize: CGSize(width: 382, height: 550), horizontalSafeArea: 84, accessibilityText: false
        ))
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 382, height: 700), controlsHeight: IPhoneDeckLayout.controlsHeight,
            horizontalSafeArea: 84, accessibilityText: false
        ) == IPhoneDeckLayout.maximumDisplayHeight)
    }

    @Test(arguments: [
        (CGSize(width: 200, height: 300), CGFloat(208)),
        (CGSize(width: 382, height: 510), CGFloat(240))
    ])
    func lessSpaceOrTallerTextPreservesTheSpectrumAndAllowsScrolling(
        availableSize: CGSize, controlsHeight: CGFloat
    ) {
        let height = IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: controlsHeight,
            horizontalSafeArea: 84, accessibilityText: false
        )
        #expect(height == IPhoneDeckLayout.minimumSpectrumDisplayHeight)
        #expect(IPhoneDeckLayout.visualizerHeight(displayHeight: height, compactControls: true) == 44)
        #expect(stackHeight(displayHeight: height, controlsHeight: controlsHeight) > availableSize.height)
    }

    /// Closed landscape (678 × 466 pt) leaves about 590 pt beside its vertical toolbar.
    @Test(arguments: [CGFloat(584), 590, 750])
    func compactLandscapePlacesTheControlsBesideTheDisplay(availableWidth: CGFloat) {
        let availableSize = CGSize(width: availableWidth, height: 300)
        #expect(IPhoneDeckLayout.usesSideBySide(availableSize: availableSize))
        let widths = IPhoneDeckLayout.sideBySideWidths(availableWidth: availableWidth)
        #expect(widths.controls >= IPhoneDeckLayout.minimumControlsWidth)
        #expect(widths.display >= IPhoneDeckLayout.minimumSideBySideDisplayWidth)
        #expect(widths.controls + widths.display + IPhoneDeckLayout.groupSpacing + 2 * IPhoneDeckLayout.gutter
            == availableWidth)
    }

    @Test(arguments: [CGSize(width: 583, height: 300), CGSize(width: 382, height: 510),
                      CGSize(width: 700, height: 700)])
    func narrowOrPortraitDecksKeepTheVerticalStack(availableSize: CGSize) {
        #expect(!IPhoneDeckLayout.usesSideBySide(availableSize: availableSize))
    }

    @Test(arguments: [(CGFloat(285), CGFloat(259)), (500, 340)])
    func sideBySideDisplayTakesTheHeightAboveThePageSwitcher(availableHeight: CGFloat, expected: CGFloat) {
        #expect(IPhoneDeckLayout.sideBySideDisplayHeight(availableHeight: availableHeight) == expected)
    }

    @Test(arguments: [CGFloat(254), 270, 300])
    func compactSpectrumLeavesSpaceForAllPhoneDeckInformation(displayHeight: CGFloat) {
        let height = IPhoneDeckLayout.visualizerHeight(displayHeight: displayHeight, compactControls: true)
        #expect(height >= 44)
        #expect(height + 210 <= displayHeight)
    }

    @Test func otherLayoutsKeepTheExistingSpectrumAllocation() {
        #expect(IPhoneDeckLayout.visualizerHeight(displayHeight: 90, compactControls: false) == 20)
        #expect(IPhoneDeckLayout.visualizerHeight(displayHeight: 250, compactControls: false) == 70)
        #expect(IPhoneDeckLayout.visualizerHeight(displayHeight: 300, compactControls: false) == 88)
        #expect(IPhoneDeckLayout.visualizerHeight(displayHeight: 340, compactControls: false) == 88)
    }
}

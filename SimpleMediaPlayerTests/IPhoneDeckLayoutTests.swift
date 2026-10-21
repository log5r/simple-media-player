import CoreGraphics
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct IPhoneDeckLayoutTests {
    @Test func closedDisplayFitsTheSmallerControlsAndFullSpectrum() {
        let availableSize = CGSize(width: 382, height: 498)
        #expect(IPhoneDeckLayout.usesCompactControls(
            availableSize: availableSize, horizontalSafeArea: 84, accessibilityText: false
        ))
        let height = IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: 202, horizontalSafeArea: 84, accessibilityText: false
        )
        #expect(height == 270)
        #expect(IPhoneDeckLayout.visualizerHeight(displayHeight: height, compactControls: true) == 60)
        #expect(height + IPhoneDeckLayout.displayBezelHeight + IPhoneDeckLayout.compactSpacing
            + 202 + IPhoneDeckLayout.compactBottomPadding == availableSize.height)
    }

    @Test(arguments: [CGFloat(300), 500, 700])
    func ordinaryPhonesKeepTheExistingDisplayHeight(availableHeight: CGFloat) {
        let availableSize = CGSize(width: 375, height: availableHeight)
        #expect(!IPhoneDeckLayout.usesCompactControls(
            availableSize: availableSize, horizontalSafeArea: 0, accessibilityText: false
        ))
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: 272, horizontalSafeArea: 0, accessibilityText: false
        ) == 300)
    }

    @Test func accessibilityTextKeepsTheExistingScrollableDisplay() {
        let availableSize = CGSize(width: 382, height: 498)
        #expect(!IPhoneDeckLayout.usesCompactControls(
            availableSize: availableSize, horizontalSafeArea: 84, accessibilityText: true
        ))
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: 400, horizontalSafeArea: 84, accessibilityText: true
        ) == 300)
    }

    @Test func compactControlChoiceUsesTheStableRegularHeight() {
        #expect(IPhoneDeckLayout.usesCompactControls(
            availableSize: CGSize(width: 382, height: 611), horizontalSafeArea: 84, accessibilityText: false
        ))
        #expect(!IPhoneDeckLayout.usesCompactControls(
            availableSize: CGSize(width: 382, height: 612), horizontalSafeArea: 84, accessibilityText: false
        ))
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 382, height: 700), controlsHeight: 272,
            horizontalSafeArea: 84, accessibilityText: false
        ) == 300)
    }

    @Test(arguments: [
        (CGSize(width: 200, height: 300), CGFloat(202)),
        (CGSize(width: 382, height: 498), CGFloat(230))
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
        #expect(height + IPhoneDeckLayout.displayBezelHeight + IPhoneDeckLayout.compactSpacing
            + controlsHeight + IPhoneDeckLayout.compactBottomPadding > availableSize.height)
    }

    @Test func ordinaryPhoneLandscapeKeepsTheExistingControlsBesideTheSensorSafeArea() {
        let availableSize = CGSize(width: 700, height: 300)
        #expect(!IPhoneDeckLayout.usesCompactControls(
            availableSize: availableSize, horizontalSafeArea: 59, accessibilityText: false
        ))
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: availableSize, controlsHeight: 272, horizontalSafeArea: 59, accessibilityText: false
        ) == 300)
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
    }
}

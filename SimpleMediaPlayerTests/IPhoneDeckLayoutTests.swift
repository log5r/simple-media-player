import CoreGraphics
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct IPhoneDeckLayoutTests {
    @Test(arguments: [CGFloat(272), 320])
    func closedDisplayLeavesRoomForTheMeasuredControls(controlsHeight: CGFloat) {
        let availableHeight: CGFloat = 500
        let height = IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 382, height: availableHeight), controlsHeight: controlsHeight,
            horizontalSafeArea: 84, accessibilityText: false
        )
        #expect(height < 300)
        #expect(height + IPhoneDeckLayout.displayBezelHeight + IPhoneDeckLayout.spacing
            + controlsHeight + IPhoneDeckLayout.bottomPadding <= availableHeight)
    }

    @Test(arguments: [CGFloat(300), 500, 700])
    func ordinaryPhonesKeepTheExistingDisplayHeight(availableHeight: CGFloat) {
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 375, height: availableHeight), controlsHeight: 272,
            horizontalSafeArea: 0, accessibilityText: false
        ) == 300)
    }

    @Test func accessibilityTextKeepsTheExistingScrollableDisplay() {
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 382, height: 500), controlsHeight: 400,
            horizontalSafeArea: 84, accessibilityText: true
        ) == 300)
    }

    @Test func largerDisplaysKeepTheExistingHeightAndVeryShortDisplaysRemainScrollable() {
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 382, height: 700), controlsHeight: 272,
            horizontalSafeArea: 84, accessibilityText: false
        ) == 300)
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 200, height: 300), controlsHeight: 272,
            horizontalSafeArea: 84, accessibilityText: false
        ) == 90)
    }

    @Test func ordinaryPhoneLandscapeKeepsTheExistingHeightBesideTheSensorSafeArea() {
        #expect(IPhoneDeckLayout.displayHeight(
            availableSize: CGSize(width: 700, height: 300), controlsHeight: 272,
            horizontalSafeArea: 59, accessibilityText: false
        ) == 300)
    }
}

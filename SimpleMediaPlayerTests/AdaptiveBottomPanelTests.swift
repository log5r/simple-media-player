import CoreGraphics
import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct AdaptiveBottomPanelTests {
    @Test func wideDeckAllocatesControlsFromTheirMinimumWidth() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 180)
        let placement = AdaptiveBottomPanelPlacement.make(in: bounds, avoiding: [], side: .right, layout: .ledHalf)

        #expect(placement.controls.width == AdaptiveBottomPanelMetrics.inlineControlWidth)
        #expect(placement.display.width == 374)
        #expect(placement.controls.maxX == placement.display.minX)
        #expect(bounds.contains(placement.controls))
        #expect(bounds.contains(placement.display))
    }

    @Test func narrowDeckStacksWithoutReducingTheControlsTouchTargets() {
        let width: CGFloat = 500
        let height = AdaptiveBottomPanelMetrics.height(width: width, layout: .ledHalf)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let placement = AdaptiveBottomPanelPlacement.make(in: bounds, avoiding: [], side: .left, layout: .ledHalf)

        #expect(placement.display.height == 153)
        #expect(placement.controls.height == 236)
        #expect(placement.display.maxY == placement.controls.minY)
        #expect(placement.controls.width == width)
    }

    @Test func controlsSwitchRowsAtTheSpaceRequiredByTheirContent() {
        #expect(AdaptiveBottomPanelMetrics.height(width: 825, layout: .ledHalf) == 236)
        #expect(AdaptiveBottomPanelMetrics.height(width: 826, layout: .ledHalf) == 180)
        #expect(AdaptiveBottomPanelMetrics.height(width: 631, layout: .ledHalf) == 389)
        #expect(AdaptiveBottomPanelMetrics.height(width: 632, layout: .ledHalf) == 236)
    }

    @Test(arguments: [CGFloat(500), CGFloat(900)])
    func classicDisplayKeepsItsStandardDisplayHeight(width: CGFloat) {
        let height = AdaptiveBottomPanelMetrics.height(width: width, layout: .classic)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let placement = AdaptiveBottomPanelPlacement.make(in: bounds, avoiding: [], side: .right, layout: .classic)

        #expect(placement.display.height == 117)
        #expect(placement.controls.height == AdaptiveBottomPanelMetrics.controlHeight(width: width, layout: .classic))
        #expect(placement.display.maxY == placement.controls.minY)
    }

    @Test(arguments: [LEDPanelSide.left, .right])
    func verticalDivisionPlacesEachPanelOnOneSide(side: LEDPanelSide) {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 236)
        let division = CGRect(x: 438, y: 0, width: 24, height: 236)
        let placement = AdaptiveBottomPanelPlacement.make(
            in: bounds, avoiding: [division], side: side, layout: .ledHalf
        )

        #expect(!overlaps(placement.controls, division))
        #expect(!overlaps(placement.display, division))
        #expect(side == .left ? placement.display.maxX <= division.minX :
                    placement.display.minX >= division.maxX)
    }

    @Test func horizontalDivisionPlacesDisplayAboveControls() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 236)
        let division = CGRect(x: 0, y: 108, width: 700, height: 20)
        let placement = AdaptiveBottomPanelPlacement.make(
            in: bounds, avoiding: [division], side: .right, layout: .ledHalf
        )

        #expect(placement.display.maxY <= division.minY)
        #expect(placement.controls.minY >= division.maxY)
    }

    @Test func verticalDivisionHeightConvergesUsingTheLocalControlWidth() {
        let division = CGRect(x: 435.5, y: -500, width: 80, height: 1_500)
        for height in [CGFloat(180), CGFloat(236)] {
            let bounds = CGRect(x: 0, y: 0, width: 951, height: height)
            let placement = AdaptiveBottomPanelPlacement.make(
                in: bounds, avoiding: [division], side: .right, layout: .ledHalf
            )
            let width = placement.controlWidthForVerticalDivision(in: bounds, divisionFrames: [division])
            #expect(width == 435.5)
            #expect(AdaptiveBottomPanelMetrics.height(width: 951, layout: .ledHalf, dividedControlWidth: width) == 236)
        }
        #expect(AdaptiveBottomPanelMetrics.height(width: 951, layout: .ledHalf, dividedControlWidth: nil) == 180)
    }

    @Test func horizontalDivisionDoesNotDriveAHeightFeedbackLoop() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 180)
        let division = CGRect(x: 0, y: 60, width: 900, height: 60)
        let placement = AdaptiveBottomPanelPlacement.make(
            in: bounds, avoiding: [division], side: .right, layout: .ledHalf
        )
        #expect(placement.controlWidthForVerticalDivision(in: bounds, divisionFrames: [division]) == nil)
    }

    @Test func occlusionAndMultipleReservationsLeaveDisjointSafeRectangles() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 236)
        let reservations = [CGRect(x: 850, y: 0, width: 50, height: 50),
                            CGRect(x: 438, y: 0, width: 24, height: 236)]
        let frames = DeckSafeRegions.frames(in: bounds, avoiding: reservations)

        for frame in frames {
            #expect(bounds.contains(frame))
            for reservation in reservations {
                #expect(!overlaps(frame, reservation))
            }
        }
        for (index, frame) in frames.enumerated() {
            for other in frames.dropFirst(index + 1) {
                #expect(!overlaps(frame, other))
            }
        }
    }

    @Test func absentAndOutsideRegionsPreserveTheNormalLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 180)
        let outside = CGRect(x: 20, y: 200, width: 20, height: 20)
        #expect(DeckSafeRegions.frames(in: bounds, avoiding: [outside]) == [bounds])
        #expect(DeckSafeRegions.frames(in: bounds, avoiding: [bounds]).isEmpty)
    }

    @Test func seekCompletionRequiresTheSameItemAndPlaybackGeneration() {
        let itemID = UUID()
        let target = PlaybackSeekTarget(itemID: itemID, generation: 7)

        #expect(target.isValid(itemID: itemID, generation: 7))
        #expect(!target.isValid(itemID: UUID(), generation: 7))
        #expect(!target.isValid(itemID: nil, generation: 7))
        #expect(!target.isValid(itemID: itemID, generation: 8))
        #expect(!PlaybackSeekTarget(itemID: nil, generation: 7).isValid(itemID: nil, generation: 7))
    }

    private func overlaps(_ first: CGRect, _ second: CGRect) -> Bool {
        let intersection = first.intersection(second)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
}

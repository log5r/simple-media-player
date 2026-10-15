import CoreGraphics
import SwiftUI
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct DuoPortraitPlayerLayoutTests {
    @Test func portraitPlayerRequiresAnExpandedDivisibleDisplay() {
        let portrait = CGSize(width: 669, height: 835)
        #expect(DuoPortraitPlayerLayout.isPreferred(size: portrait, compact: false, hasDisplayDivision: true))
        #expect(!DuoPortraitPlayerLayout.isPreferred(size: portrait, compact: true, hasDisplayDivision: true))
        #expect(!DuoPortraitPlayerLayout.isPreferred(size: portrait, compact: false, hasDisplayDivision: false))
        #expect(!DuoPortraitPlayerLayout.isPreferred(size: CGSize(width: 835, height: 669),
                                                    compact: false, hasDisplayDivision: true))
    }

    /// The division frame matches the partially folded portrait Duo, including its 20 pt margins.
    @Test func foldedLibraryStartsBelowTheDivision() {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 835)
        let division = CGRect(x: 0, y: 373.5, width: 669, height: 40)
        let foldBottom = DuoPortraitPlayerLayout.foldBottom(in: bounds, divisionFrames: [division])
        #expect(foldBottom == division.maxY)
        #expect(DuoPortraitPlayerLayout.libraryTop(in: bounds, foldBottom: foldBottom) == division.maxY)
    }

    @Test func openOrSideBySideDivisionsKeepTheFullLibrary() {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 835)
        let vertical = CGRect(x: 314.5, y: 0, width: 40, height: 835)
        let outside = CGRect(x: 0, y: 900, width: 669, height: 40)
        for frames in [[], [vertical], [outside]] {
            let foldBottom = DuoPortraitPlayerLayout.foldBottom(in: bounds, divisionFrames: frames)
            #expect(foldBottom == nil)
            #expect(DuoPortraitPlayerLayout.libraryTop(in: bounds, foldBottom: foldBottom) == nil)
        }
    }

    /// The keyboard shortens the view, so the Library returns above it instead of shrinking under the fold.
    @Test func keyboardLeavingTooLittleRoomBelowTheFoldKeepsTheFullLibrary() {
        let division = CGRect(x: 0, y: 373.5, width: 669, height: 40)
        let withKeyboard = CGRect(x: 0, y: 0, width: 669, height: 430)
        let foldBottom = DuoPortraitPlayerLayout.foldBottom(in: withKeyboard, divisionFrames: [division])
        #expect(foldBottom == division.maxY)
        #expect(DuoPortraitPlayerLayout.libraryTop(in: withKeyboard, foldBottom: foldBottom) == nil)

        let minimum = CGRect(x: 0, y: 0, width: 669,
                             height: division.maxY + DuoPortraitPlayerLayout.minimumFoldedLibraryHeight)
        #expect(DuoPortraitPlayerLayout.libraryTop(in: minimum, foldBottom: foldBottom) == division.maxY)
        let belowMinimum = CGRect(x: 0, y: 0, width: 669, height: minimum.height - 1)
        #expect(DuoPortraitPlayerLayout.libraryTop(in: belowMinimum, foldBottom: foldBottom) == nil)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 669, height: 835),
        CGRect(x: 10, y: 20, width: 669, height: 787)
    ])
    func portraitSplitsAtTheCenterWithoutAGap(bounds: CGRect) {
        let placement = DuoPortraitPlayerPlacement.make(in: bounds, occlusionFrames: [])
        #expect(placement.visuals.height == bounds.height / 2)
        #expect(placement.controls.height == bounds.height / 2)
        #expect(placement.led.height == bounds.height / 4)
        #expect(placement.meters.height == bounds.height / 4)
        #expect(placement.led.width == bounds.width)
        #expect(placement.meters.width == bounds.width)
        #expect(placement.led.maxY == placement.meters.minY)
        #expect(placement.meters.maxY == placement.controls.minY)
    }

    @Test func activeCamerasAreStillAvoidedInBothHalves() {
        let bounds = CGRect(x: 10, y: 20, width: 700, height: 900)
        let cameras = [CGRect(x: 650, y: 20, width: 60, height: 70),
                       CGRect(x: 10, y: 850, width: 60, height: 70)]
        let placement = DuoPortraitPlayerPlacement.make(in: bounds, occlusionFrames: cameras)
        for frame in [placement.led, placement.meters, placement.controls] {
            #expect(bounds.contains(frame))
            for reserved in cameras {
                let intersection = frame.intersection(reserved)
                #expect(intersection.isNull || intersection.isEmpty)
            }
        }
    }

    @Test func outsideOcclusionDoesNotDisplaceTheCenterSplit() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let outside = CGRect(x: 0, y: 900, width: 600, height: 40)
        #expect(DuoPortraitPlayerPlacement.make(in: bounds, occlusionFrames: [outside]) ==
            DuoPortraitPlayerPlacement.make(in: bounds, occlusionFrames: []))
    }

    @Test(arguments: LEDPanelSide.allCases)
    func adaptiveLEDCornersStayFixedAwayFromTheWindowCorner(side: LEDPanelSide) {
        let outerStyles = LEDPanelCorner.adaptive.cornerStyles(side: side, meetsWindowCorner: false)
        let innerStyles = LEDPanelCorner.adaptive.cornerStyles(side: side, inset: 1, meetsWindowCorner: false)
        #expect(outerStyles == LEDPanelCornerStyles(
            topLeading: .fixed(2), topTrailing: .fixed(2), bottomLeading: .fixed(2), bottomTrailing: .fixed(2)
        ))
        #expect(innerStyles == LEDPanelCornerStyles(
            topLeading: .fixed(1), topTrailing: .fixed(1), bottomLeading: .fixed(1), bottomTrailing: .fixed(1)
        ))
    }

    @Test(arguments: LEDPanelSide.allCases)
    func roundedLEDCornersIgnoreTheWindowCorner(side: LEDPanelSide) {
        let styles = LEDPanelCorner.rounded.cornerStyles(side: side, meetsWindowCorner: false)
        #expect(styles == LEDPanelCorner.rounded.cornerStyles(side: side))
        #expect(styles == LEDPanelCornerStyles(
            topLeading: .fixed(9), topTrailing: .fixed(9), bottomLeading: .fixed(9), bottomTrailing: .fixed(9)
        ))
    }
}

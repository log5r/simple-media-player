import CoreGraphics
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

    @Test func openPortraitSplitsTheUpperHalfBetweenLEDAndMeters() {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 835)
        let placement = DuoPortraitPlayerPlacement.make(in: bounds, divisionFrames: [], reservedFrames: [])
        #expect(placement.visuals.height == bounds.height / 2)
        #expect(placement.controls.height == bounds.height / 2)
        #expect(placement.led.height == bounds.height / 4)
        #expect(placement.meters.height == bounds.height / 4)
        #expect(placement.led.width == bounds.width)
        #expect(placement.meters.width == bounds.width)
        #expect(placement.led.maxY == placement.meters.minY)
        #expect(placement.meters.maxY == placement.controls.minY)
    }

    @Test func bookPortraitKeepsLEDAndMetersAboveTheHingeAndEveryControlBelowIt() {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 835)
        let hingeWithMargins = CGRect(x: 0, y: 353.5, width: 669, height: 80)
        let placement = DuoPortraitPlayerPlacement.make(in: bounds, divisionFrames: [hingeWithMargins],
                                                       reservedFrames: [hingeWithMargins])
        #expect(placement.led.maxY <= hingeWithMargins.minY)
        #expect(placement.meters.maxY <= hingeWithMargins.minY)
        #expect(placement.led.height == placement.meters.height)
        #expect(placement.controls.minY >= hingeWithMargins.maxY)
        #expect(placement.controls.height == 401.5)
        #expect(placement.led.width == bounds.width)
    }

    @Test func activeCameraAndHingeAreAvoidedTogether() {
        let bounds = CGRect(x: 10, y: 20, width: 700, height: 900)
        let hinge = CGRect(x: 10, y: 440, width: 700, height: 60)
        let camera = CGRect(x: 650, y: 20, width: 60, height: 70)
        let placement = DuoPortraitPlayerPlacement.make(in: bounds, divisionFrames: [hinge],
                                                       reservedFrames: [hinge, camera])
        for frame in [placement.led, placement.meters, placement.controls] {
            #expect(bounds.contains(frame))
            for reserved in [hinge, camera] {
                let intersection = frame.intersection(reserved)
                #expect(intersection.isNull || intersection.isEmpty)
            }
        }
    }

    @Test func inactiveOrOutsideDivisionDoesNotDisplaceTheCenterSplit() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let outside = CGRect(x: 0, y: 900, width: 600, height: 40)
        #expect(DuoPortraitPlayerPlacement.make(in: bounds, divisionFrames: [outside], reservedFrames: [outside]) ==
            DuoPortraitPlayerPlacement.make(in: bounds, divisionFrames: [], reservedFrames: []))
    }
}

import CoreGraphics
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct FullScreenVideoLayoutTests {
    private let portrait = CGRect(x: 0, y: 0, width: 700, height: 900)
    private let fold = CGRect(x: 0, y: 430, width: 700, height: 40)

    @Test func partiallyFoldedPortraitUsesTheAreaAboveTheDivision() {
        let frame = FullScreenVideoLayout.videoFrame(in: portrait, activeDivisionFrames: [fold])
        #expect(frame == CGRect(x: 0, y: 0, width: 700, height: 430))
        #expect(frame.maxY == fold.minY)
        #expect(frame.midY < portrait.midY)
    }

    @Test func divisionCoordinatesAndMarginsDetermineTheUpperArea() {
        let bounds = CGRect(x: 20, y: 30, width: 700, height: 900)
        let division = CGRect(x: 0, y: 460, width: 740, height: 50)
        #expect(FullScreenVideoLayout.videoFrame(in: bounds, activeDivisionFrames: [division]) ==
            CGRect(x: 20, y: 30, width: 700, height: 430))
    }

    @Test func unfoldingRestoresTheEntireVideoArea() {
        #expect(FullScreenVideoLayout.videoFrame(in: portrait, activeDivisionFrames: [fold]) != portrait)
        #expect(FullScreenVideoLayout.videoFrame(in: portrait, activeDivisionFrames: []) == portrait)
    }

    @Test func landscapeKeepsTheEntireVideoArea() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        let division = CGRect(x: 430, y: 0, width: 40, height: 700)
        #expect(FullScreenVideoLayout.videoFrame(in: bounds, activeDivisionFrames: [division]) == bounds)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 950, width: 700, height: 40),
        CGRect(x: 0, y: -40, width: 700, height: 40),
        CGRect(x: 0, y: 0, width: 700, height: 40),
        CGRect(x: 0, y: 860, width: 700, height: 40),
        CGRect(x: 330, y: 0, width: 40, height: 900),
        CGRect(x: 0, y: 430, width: 60, height: 40),
        CGRect(x: 0, y: 430, width: 700, height: 0)
    ])
    func nonSplittingRegionsDoNotMoveVideo(division: CGRect) {
        #expect(FullScreenVideoLayout.videoFrame(in: portrait, activeDivisionFrames: [division]) == portrait)
    }

    @Test func upperDivisionIsChosenRegardlessOfRegionOrder() {
        let lowerFold = CGRect(x: 0, y: 650, width: 700, height: 40)
        let expected = CGRect(x: 0, y: 0, width: 700, height: 430)
        for divisions in [[fold, lowerFold], [lowerFold, fold]] {
            #expect(FullScreenVideoLayout.videoFrame(in: portrait, activeDivisionFrames: divisions) == expected)
        }
    }
}

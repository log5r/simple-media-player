#if os(iOS)
import UIKit
import XCTest

extension XCTestCase {
    /// Compare the drawn labels with the full strings in the seek bar's monospaced-digit footnote font.
    @MainActor func assertSeekTimesFit(
        in container: XCUIElement, contentSizeCategory: UIContentSizeCategory, within bounds: CGRect
    ) {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let pointSize = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).pointSize
        let font = UIFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
        let elapsed = container.staticTexts["seekElapsedTime"]
        let remaining = container.staticTexts["seekRemainingTime"]
        let slider = container.sliders["Playback Position"].frame
        for time in [elapsed, remaining] {
            XCTAssertTrue(time.waitForExistence(timeout: 5), time.identifier)
            let label = time.label
            XCTAssertFalse(label.isEmpty, time.identifier)
            let expected = (label as NSString).size(withAttributes: [.font: font])
            let frame = time.frame
            let measurement = "\(time.identifier) \(label): \(frame.width) pt, needs \(expected.width) pt"
            XCTContext.runActivity(named: measurement) { _ in
                XCTAssertGreaterThanOrEqual(frame.width, ceil(expected.width) - 1, "\(label) is truncated")
                XCTAssertGreaterThanOrEqual(frame.height, ceil(expected.height) - 1, "\(label) is clipped")
                XCTAssertGreaterThanOrEqual(frame.minY, slider.maxY - 1, "\(label) overlaps the slider")
                XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(label) outside \(bounds)")
            }
        }
        XCTAssertFalse(elapsed.frame.intersects(remaining.frame), "The times must not overlap")
    }
}
#endif

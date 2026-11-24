#if os(iOS)
import XCTest

extension XCTestCase {
    @MainActor func scrollToSetting(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        let visibleFrame = (form.exists ? form.frame : app.frame).insetBy(dx: 8, dy: 40)
        for _ in 0..<30 {
            if element.exists, element.isHittable,
               element.frame.minY >= visibleFrame.minY, element.frame.maxY <= visibleFrame.maxY { return }
            let scrollsUp = element.exists && element.frame.height > 0 && element.frame.minY < visibleFrame.minY
            let container = form.exists ? form : app
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsUp ? 0.4 : 0.8))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsUp ? 0.8 : 0.4))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not bring setting fully into view: \(element)")
    }
}
#endif

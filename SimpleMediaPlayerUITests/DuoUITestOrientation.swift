#if os(iOS)
import Darwin
import UIKit
import XCTest

extension XCTestCase {
    /// Xcode 27.1's Duo simulator can report XCTest rotation while its display stays unchanged.
    /// Enable DUO_INTERACTIVE_ORIENTATION_TESTS=1 and rotate in Device Hub when the step is logged.
    @MainActor func rotateDuo(
        to orientation: UIDeviceOrientation, in app: XCUIApplication,
        layoutIdentifier: String = "duoLayoutMetrics", portraitKey: String = "portrait",
        interactiveTimeout: TimeInterval = 45
    ) {
        let interactive = ProcessInfo.processInfo.environment["DUO_INTERACTIVE_ORIENTATION_TESTS"] == "1"
        let posture = orientation.isPortrait ? "Portrait" : "Landscape"
        if !interactive { XCUIDevice.shared.orientation = orientation }
        let layout = duoDiagnostic(layoutIdentifier, in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 5), layoutIdentifier)
        let expected = "\"\(portraitKey)\":\(orientation.isPortrait)"
        if interactive && (layout.value as? String)?.contains(expected) != true {
            print("DuoOrientationStep \(posture)")
            fflush(nil)
        }
        XCTContext.runActivity(named: "Verify actual Duo \(posture) layout") { _ in
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", expected), object: layout
            )
            wait(for: [expectation], timeout: interactive ? interactiveTimeout : 10)
            let attachment = XCTAttachment(string: layout.value as? String ?? "missing")
            attachment.name = "Duo actual \(posture) layout"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func duoDiagnostic(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)
        ).firstMatch
    }
}
#endif

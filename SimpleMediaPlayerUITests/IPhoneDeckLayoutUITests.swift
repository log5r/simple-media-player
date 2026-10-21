#if os(iOS)
import UIKit
import XCTest

final class IPhoneDeckLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone deck.")
    }

    /// Select the Duo's Closed posture in Device Hub before running this case.
    @MainActor func testClosedDuoShowsPlaybackControlsWithoutScrolling() throws {
        let app = launch()
        let geometry = try rootMetrics(in: app)
        let safeArea = geometry["safeArea"] as? [String: Double] ?? [:]
        try XCTSkipUnless(
            geometry["horizontalSizeClass"] as? String == "compact"
                && geometry["portrait"] as? Bool == true
                && (safeArea["leading", default: 0] + safeArea["trailing", default: 0]) > 0,
            "Run this case on the Duo's Closed display."
        )
        openDeck(in: app)
        let playPause = app.buttons["phonePlayPause"]
        let page = app.buttons["phonePage.Display"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.contains(playPause.frame) && playPause.frame.maxY <= page.frame.minY
        }, object: nil)
        wait(for: [visible], timeout: 5)
        for identifier in ["phoneStop", "phonePrevious", "phonePlayPause", "phoneNext", "phoneMute"] {
            let button = app.buttons[identifier]
            assertTouchTarget(button, in: app)
            XCTAssertTrue(button.isHittable, identifier)
            XCTAssertLessThanOrEqual(button.frame.maxY, page.frame.minY, identifier)
        }
        attachScreenshot(in: app, name: "Duo Closed deck before scrolling")
        playPause.tap()
        XCTAssertEqual(playPause.label, "Play")
        playPause.tap()
        XCTAssertEqual(playPause.label, "Pause")
    }

    @MainActor func testOrdinaryPhoneKeepsTheFullDisplayHeight() throws {
        let app = launch()
        let geometry = try rootMetrics(in: app)
        let divisions = geometry["division"] as? [[String: Any]] ?? []
        let safeArea = geometry["safeArea"] as? [String: Double] ?? [:]
        try XCTSkipUnless(
            geometry["portrait"] as? Bool == true && divisions.isEmpty
                && safeArea["leading", default: 0] + safeArea["trailing", default: 0] == 0,
            "Run this case on an ordinary portrait iPhone."
        )
        openDeck(in: app)
        try assertFullDisplayHeight(in: app)
        attachScreenshot(in: app, name: "Ordinary iPhone full deck display")
    }

    @MainActor func testAccessibilityDeckKeepsTheFullDisplayAndScrollableControls() throws {
        let app = launch(contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        let geometry = try rootMetrics(in: app)
        try XCTSkipUnless(
            geometry["horizontalSizeClass"] as? String == "compact",
            "Run this case on a compact iPhone display."
        )
        openDeck(in: app)
        XCTAssertTrue(app.buttons["phonePageMenu"].waitForExistence(timeout: 5))
        try assertFullDisplayHeight(in: app)
        let mute = app.buttons["phoneMute"]
        for _ in 0..<3 where !mute.isHittable { app.swipeUp() }
        assertTouchTarget(mute, in: app)
        XCTAssertTrue(mute.isHittable)
        attachScreenshot(in: app, name: "Accessibility deck controls after scrolling")
    }

    @MainActor private func launch(contentSizeCategory: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-compact-layout", "--ui-testing-duo-layout",
            "-UIPreferredContentSizeCategoryName", contentSizeCategory,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["All Songs"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func openDeck(in app: XCUIApplication) {
        app.buttons["All Songs"].tap()
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        dock.tap()
        XCTAssertTrue(app.buttons["phoneDeckClose"].waitForExistence(timeout: 5))
    }

    @MainActor private func rootMetrics(in app: XCUIApplication) throws -> [String: Any] {
        let element = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        return try metrics(element)
    }

    @MainActor private func assertFullDisplayHeight(in app: XCUIApplication) throws {
        let element = duoDiagnostic("phoneDeckCompactDisplayMetrics", in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertEqual(try XCTUnwrap(try metrics(element)["height"] as? Double), 310, accuracy: 1)
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor private func assertTouchTarget(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.exists, element.identifier)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, element.identifier)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, element.identifier)
        XCTAssertTrue(app.frame.contains(element.frame), element.identifier)
    }

    @MainActor private func attachScreenshot(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif

#if os(iOS)
import UIKit
import XCTest

final class IPhoneDeckLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone deck.")
    }

    /// Select the Duo's Closed posture in Device Hub before running this case.
    @MainActor func testClosedDuoShowsSpectrumAndPlaybackControlsWithoutScrolling() throws {
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
        let display = try regionFrame("phoneDeckCompactDisplayMetrics", in: app)
        let spectrum = try regionFrame("phoneDeckSpectrumMetrics", in: app)
        let content = try regionFrame("phoneDeckLEDContentMetrics", in: app)
        XCTAssertGreaterThanOrEqual(spectrum.height, 44)
        XCTAssertGreaterThan(spectrum.width, 100)
        XCTAssertTrue(display.contains(spectrum), "Spectrum must stay inside the visible LED display")
        XCTAssertTrue(display.contains(content), "LED metadata and spectrum must fit without clipping")
        XCTAssertLessThanOrEqual(spectrum.maxY, app.sliders["Playback Position"].frame.minY)
        try assertSingleColumn(in: app, display: display)
        for identifier in ["phoneStop", "phonePrevious", "phonePlayPause", "phoneNext", "phoneMute"] {
            let button = app.buttons[identifier]
            assertTouchTarget(button, in: app)
            XCTAssertTrue(button.isHittable, identifier)
            XCTAssertLessThanOrEqual(button.frame.maxY, page.frame.minY, identifier)
        }
        assertTouchTarget(routePicker(in: app), in: app)
        attachScreenshot(in: app, name: "Duo Closed deck before scrolling")
        playPause.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
        XCTAssertEqual(playPause.label, "Play")
        playPause.tap()
        XCTAssertEqual(playPause.label, "Pause")
    }

    @MainActor func testOrdinaryPhoneGivesSpareHeightToTheDisplay() throws {
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
        let display = try regionFrame("phoneDeckCompactDisplayMetrics", in: app)
        // The LED takes the spare height up to its 340 pt cap; the plate adds a 10 pt bezel.
        XCTAssertGreaterThanOrEqual(display.height, 310 - 1)
        XCTAssertLessThanOrEqual(display.height, 350 + 1)
        try assertSingleColumn(in: app, display: display)
        let gap = app.buttons["phonePage.Display"].frame.minY - app.buttons["phoneMute"].frame.maxY
        XCTAssertEqual(gap, 16, accuracy: 1, "No empty band may remain between the volume row and the page switcher")
        attachScreenshot(in: app, name: "Ordinary iPhone deck display")
    }

    /// The landscape deck places the controls on the left and the LED on the right without scrolling.
    /// Setting the device orientation does not rotate the Duo's Closed display, so the case needs an ordinary iPhone.
    @MainActor func testCompactLandscapePlacesControlsBesideTheDisplay() throws {
        let app = launch()
        let geometry = try rootMetrics(in: app)
        let safeArea = geometry["safeArea"] as? [String: Double] ?? [:]
        try XCTSkipUnless(
            geometry["horizontalSizeClass"] as? String == "compact"
                && (geometry["division"] as? [[String: Any]] ?? []).isEmpty
                && safeArea["leading", default: 0] + safeArea["trailing", default: 0] == 0,
            "Run this case on an ordinary compact iPhone."
        )
        openDeck(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let playPause = app.buttons["phonePlayPause"]
        let display = duoDiagnostic("phoneDeckCompactDisplayMetrics", in: app)
        let beside = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && playPause.exists
                && (try? self.frame(of: display)).map { playPause.frame.maxX < $0.minX } == true
        }, object: nil)
        wait(for: [beside], timeout: 10)
        let ledFrame = try frame(of: display)
        let page = app.buttons["phonePage.Display"]
        for identifier in ["phoneStop", "phonePlayPause", "phoneNext", "phoneMute"] {
            let button = app.buttons[identifier]
            assertTouchTarget(button, in: app)
            XCTAssertTrue(button.isHittable, identifier)
            XCTAssertLessThanOrEqual(button.frame.maxY, page.frame.minY, identifier)
        }
        XCTAssertEqual(ledFrame.minX - app.buttons["phoneNext"].frame.maxX, 16, accuracy: 1)
        XCTAssertEqual(page.frame.minY - ledFrame.maxY, 16, accuracy: 1)
        XCTAssertEqual(routePicker(in: app).frame.maxX, app.buttons["phoneNext"].frame.maxX, accuracy: 1)
        attachScreenshot(in: app, name: "Compact landscape deck")
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
        let display = try regionFrame("phoneDeckCompactDisplayMetrics", in: app)
        let content = try regionFrame("phoneDeckLEDContentMetrics", in: app)
        XCTAssertTrue(display.contains(content), "LED text must fit the plate instead of widening the column")
        try assertSingleColumn(in: app, display: display, accessibilityText: true)
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

    /// The LED never drops below its regular 300 pt, and spare height may grow it up to 340 pt (plus the bezel).
    @MainActor private func assertFullDisplayHeight(in app: XCUIApplication) throws {
        let element = duoDiagnostic("phoneDeckCompactDisplayMetrics", in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let height = try XCTUnwrap(try metrics(element)["height"] as? Double)
        XCTAssertGreaterThanOrEqual(height, 309)
        XCTAssertLessThanOrEqual(height, 351)
    }

    /// The LED and every control row share one column; the rows are 44 pt and Play/Pause is twice as wide.
    /// Accessibility text may make the lamps and the page menu taller, but not wider.
    @MainActor private func assertSingleColumn(
        in app: XCUIApplication, display: CGRect, accessibilityText: Bool = false
    ) throws {
        let buttons = app.buttons
        // The accessibility page menu reports the whole row as its frame, so measure the drawn switcher.
        let pages = accessibilityText ? try regionFrame("phoneDeckPageSwitcherMetrics", in: app)
            : buttons["phonePage.Display"].frame.union(buttons["phonePage.Up Next"].frame)
        let rows: [(String, CGRect)] = [
            ("seek", try regionFrame("phoneDeckSeekMetrics", in: app)),
            ("lamps", buttons["phoneLamp.EQ"].frame.union(buttons["phoneLamp.SPEED"].frame)),
            ("transport", buttons["phoneStop"].frame.union(buttons["phoneNext"].frame)),
            ("volume", buttons["phoneMute"].frame.union(routePicker(in: app).frame)),
            ("pages", pages)
        ]
        let textRows: Set = ["lamps", "pages"]
        for (name, frame) in rows {
            XCTAssertEqual(frame.minX, display.minX, accuracy: 1, "\(name) leading edge")
            XCTAssertEqual(frame.maxX, display.maxX, accuracy: 1, "\(name) trailing edge")
            if !accessibilityText || !textRows.contains(name) {
                XCTAssertEqual(frame.height, 44, accuracy: 1, "\(name) height")
            } else {
                XCTAssertGreaterThanOrEqual(frame.height, 44 - 1, "\(name) height")
            }
        }
        let stop = buttons["phoneStop"].frame
        XCTAssertEqual(buttons["phonePrevious"].frame.width, stop.width, accuracy: 1)
        XCTAssertEqual(buttons["phoneNext"].frame.width, stop.width, accuracy: 1)
        XCTAssertEqual(buttons["phonePlayPause"].frame.width, stop.width * 2, accuracy: 1)
        let route = routePicker(in: app).frame
        XCTAssertEqual(route.width, 44, accuracy: 1)
        XCTAssertEqual(route.minY, buttons["phoneMute"].frame.minY, accuracy: 1, "AirPlay shares the volume row")
    }

    @MainActor private func routePicker(in app: XCUIApplication) -> XCUIElement {
        duoDiagnostic("phoneRoutePicker", in: app)
    }

    @MainActor private func regionFrame(_ identifier: String, in app: XCUIApplication) throws -> CGRect {
        let element = duoDiagnostic(identifier, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        return try frame(of: element)
    }

    @MainActor private func frame(of element: XCUIElement) throws -> CGRect {
        let values = try metrics(element)
        return CGRect(
            x: try XCTUnwrap(values["x"] as? Double), y: try XCTUnwrap(values["y"] as? Double),
            width: try XCTUnwrap(values["width"] as? Double), height: try XCTUnwrap(values["height"] as? Double)
        )
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

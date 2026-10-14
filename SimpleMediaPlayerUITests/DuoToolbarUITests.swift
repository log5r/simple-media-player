#if os(iOS)
import UIKit
import XCTest

/// Run in Device Hub's Open landscape posture to exercise the native vertical toolbar.
final class DuoToolbarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUO_TOOLBAR_INPUT_TESTS"] == "1",
                          "Enable only when XCTest can capture and target the active Duo display.")
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Run on iPhone Duo.")
    }

    @MainActor func testLandscapeFiltersButtonOpensAbovePlaybackPanel() throws {
        let app = try launchExpanded()
        let filters = app.buttons["advancedSearchButton"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertTrue(filters.isHittable)
        XCTAssertTrue(app.frame.contains(filters.frame))
        filters.tap()
        let done = app.buttons["advancedSearchDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertTrue(filters.isHittable)

        let play = app.buttons["playButton"]
        XCTAssertTrue(play.isHittable)
        play.tap()
        let pause = app.buttons["pauseButton"]
        XCTAssertTrue(pause.isEnabled)
        XCTAssertTrue(pause.isHittable)
        pause.tap()
        wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "\"paused\":true"),
            object: duoDiagnostic("duoPlaybackMetrics", in: app)
        )], timeout: 5)
    }

    @MainActor func testLandscapeSearchFiltersAndRestoresLibrary() throws {
        let app = try launchExpanded()
        let field = app.searchFields.firstMatch
        if !field.isHittable {
            let search = app.buttons["Search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            XCTAssertTrue(search.isHittable)
            search.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        field.tap()
        let query = "No Matching Toolbar Track"
        field.typeText(query)
        XCTAssertTrue(app.staticTexts["No Media"].waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
        let track = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'libraryTrack.' AND label CONTAINS 'Layout Track 1'")
        ).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
    }

    @MainActor private func launchExpanded() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-reset-led-settings",
            "--ui-testing-duo-autoplay-probe", "--ui-testing-duo-long-playback",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let value = try XCTUnwrap(layout.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        let geometry = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try XCTSkipIf((geometry["division"] as? [[String: Any]] ?? []).isEmpty, "Run on iPhone Duo.")
        try XCTSkipUnless(geometry["portrait"] as? Bool == false, "Select Open landscape in Device Hub.")
        XCTAssertEqual(geometry["layout"] as? String, "expanded")

        let capture = app.screenshot()
        try XCTSkipUnless(capture.image.size.width > capture.image.size.height,
                          "XCTest captures the inactive display; verify toolbar taps in Device Hub.")
        let screenshot = XCTAttachment(screenshot: capture)
        screenshot.name = "Duo landscape toolbar above playback panel"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        return app
    }
}
#endif

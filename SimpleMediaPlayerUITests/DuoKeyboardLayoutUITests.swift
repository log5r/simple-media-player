#if os(iOS)
import UIKit
import XCTest

/// Run on the actual Open or Book portrait posture in Device Hub.
final class DuoKeyboardLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the Duo phone layout.")
    }

    @MainActor func testPortraitLibrarySurvivesSearchKeyboardPresentationAndDismissal() throws {
        let app = try launchPortrait()
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        app.buttons["pauseButton"].tap()
        waitForValue("\"paused\":true", in: playback)
        let originalPlayback = try metrics(playback)
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        let originalLayout = try metrics(layout)

        app.buttons["duoShowLibrary"].tap()
        let closeLibrary = app.buttons["duoCloseLibrary"]
        XCTAssertTrue(closeLibrary.waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        waitForValue("\"portrait\":false", in: layout)
        XCTAssertTrue(closeLibrary.exists, "The keyboard must not switch the portrait Library to another layout.")

        let keyboardLayout = try metrics(layout)
        XCTAssertLessThan(try number("height", in: keyboardLayout), try number("width", in: keyboardLayout))
        XCTAssertEqual(try number("width", in: keyboardLayout), try number("width", in: originalLayout), accuracy: 1)
        search.typeText("Layout Track 2")
        let secondTrack = track("Layout Track 2", in: app)
        XCTAssertTrue(secondTrack.waitForExistence(timeout: 10))
        waitForDisappearance(track("Layout Track 1", in: app))
        XCTAssertTrue(closeLibrary.exists)
        XCTAssertTrue(search.isHittable, "Search must remain above the keyboard.")

        let cancelSearch = app.buttons["close"].firstMatch
        XCTAssertTrue(cancelSearch.waitForExistence(timeout: 5))
        cancelSearch.tap()
        waitForDisappearance(keyboard)
        waitForValue("\"portrait\":true", in: layout)
        XCTAssertTrue(closeLibrary.exists, "Dismissing the keyboard must preserve the open Library.")
        XCTAssertFalse(app.buttons["duoShowLibrary"].exists)
        XCTAssertTrue(track("Layout Track 1", in: app).waitForExistence(timeout: 10))

        let currentPlayback = try metrics(playback)
        XCTAssertEqual(currentPlayback["itemID"] as? String, originalPlayback["itemID"] as? String)
        XCTAssertEqual(currentPlayback["queueIDs"] as? [String], originalPlayback["queueIDs"] as? [String])
        XCTAssertEqual(try number("generation", in: currentPlayback), try number("generation", in: originalPlayback))
        XCTAssertEqual(currentPlayback["paused"] as? Bool, true)
        closeLibrary.tap()
        XCTAssertTrue(app.buttons["duoShowLibrary"].waitForExistence(timeout: 5))
    }

    @MainActor private func launchPortrait() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout",
            "--ui-testing-duo-autoplay-probe", "--ui-testing-duo-long-playback",
            "-mediaListColumnOrder", "index,title,artist,album,duration",
            "-mediaListVisibleColumns", "index,title,artist,album,duration",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let geometry = try metrics(layout)
        try XCTSkipIf((geometry["division"] as? [[String: Any]] ?? []).isEmpty, "Run on iPhone Duo in Device Hub.")
        try XCTSkipUnless(geometry["portrait"] as? Bool == true, "Select the actual portrait posture in Device Hub.")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(geometry["layout"] as? String, "expanded")
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        waitForValue("\"title\":\"Layout Track 1\"", in: playback)
        waitForValue("\"playing\":true", in: playback)
        XCTAssertTrue(app.buttons["pauseButton"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func track(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'libraryTrack.' AND label CONTAINS %@", title
        )).firstMatch
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func number(_ key: String, in values: [String: Any]) throws -> Double {
        try XCTUnwrap(values[key] as? Double)
    }

    @MainActor private func waitForValue(_ value: String, in element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", value), object: element
        )
        wait(for: [expectation], timeout: 10)
    }

    @MainActor private func waitForDisappearance(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        wait(for: [expectation], timeout: 10)
    }
}
#endif

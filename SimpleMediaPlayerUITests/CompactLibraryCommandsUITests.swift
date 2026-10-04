#if os(iOS)
import UIKit
import XCTest

final class CompactLibraryCommandsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "This suite verifies compact iPad commands.")
    }

    @MainActor func testCompactIPadPlaybackCommandsPauseAndChangeTracks() {
        let app = launchCompact()
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)

        app.typeKey(" ", modifierFlags: [])
        waitForValue("\"paused\":true", in: playback)
        app.typeKey(" ", modifierFlags: [])
        waitForValue("\"playing\":true", in: playback)
        app.typeKey(.rightArrow, modifierFlags: .command)
        waitForValue("\"title\":\"Layout Track 2\"", in: playback)
        app.typeKey(" ", modifierFlags: [])
        waitForValue("\"paused\":true", in: playback)
        app.typeKey(.leftArrow, modifierFlags: .command)
        // Previous first restarts a track after three seconds. A second press then selects its predecessor.
        if (playback.value as? String)?.contains("\"title\":\"Layout Track 2\"") == true {
            app.typeKey(.leftArrow, modifierFlags: .command)
        }
        waitForValue("\"title\":\"Layout Track 1\"", in: playback)
    }

    @MainActor func testCompactInfoCommandUsesTheDisplayedProjectionAndRejectsHiddenItems() throws {
        let app = launchCompact()
        app.buttons["All Songs"].tap()
        let second = track("Layout Track 2", in: app)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.tap()
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        waitForValue("\"title\":\"Layout Track 2\"", in: playback)
        app.buttons["phoneDockPlayPause"].tap()
        waitForValue("\"paused\":true", in: playback)
        let selectedID = try selectedItemID(in: app)

        app.typeKey("i", modifierFlags: .command)

        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        waitForValue("\"infoItemID\":\"\(selectedID)\"", in: duoDiagnostic("duoSessionMetrics", in: app))
        close.tap()
        waitForDisappearance(close)

        tab("Search", in: app).tap()
        let third = track("Layout Track 3", in: app)
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        third.tap()
        waitForValue("\"title\":\"Layout Track 3\"", in: playback)
        app.buttons["phoneDockPlayPause"].tap()
        waitForValue("\"paused\":true", in: playback)
        let hiddenID = try selectedItemID(in: app)
        let search = app.searchFields.firstMatch
        if !search.exists {
            let revealSearch = app.navigationBars["Search"].buttons["Search"]
            XCTAssertTrue(revealSearch.waitForExistence(timeout: 5))
            revealSearch.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Layout Track 1")
        waitForDisappearance(third)
        XCTAssertEqual(try selectedItemID(in: app), hiddenID)
        let hideKeyboard = app.keyboards.buttons["Hide keyboard"]
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5))
        hideKeyboard.tap()

        assertInfoCommandDoesNotPresent(in: app)
    }

    @MainActor func testCompactInfoCommandIsUnavailableAtRootsAndCategories() throws {
        let app = launchCompact()
        app.buttons["All Songs"].tap()
        let second = track("Layout Track 2", in: app)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.tap()
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        waitForValue("\"title\":\"Layout Track 2\"", in: playback)
        app.buttons["phoneDockPlayPause"].tap()
        waitForValue("\"paused\":true", in: playback)
        _ = try selectedItemID(in: app)

        tab("Playlists", in: app).tap()
        XCTAssertTrue(app.buttons["Layout Playlist"].waitForExistence(timeout: 5))
        waitForValue("\"selectedItemID\":\"\"", in: duoDiagnostic("duoSelectionMetrics", in: app))
        assertInfoCommandDoesNotPresent(in: app)
        tab("Library", in: app).tap()
        XCTAssertTrue(app.navigationBars["All Songs"].waitForExistence(timeout: 5))
        app.navigationBars["All Songs"].buttons.element(boundBy: 0).tap()
        app.buttons["Albums"].tap()
        XCTAssertTrue(app.buttons["libraryGroup.albums.Layout Album"].waitForExistence(timeout: 10))
        waitForValue("\"selectedItemID\":\"\"", in: duoDiagnostic("duoSelectionMetrics", in: app))
        assertInfoCommandDoesNotPresent(in: app)
    }

    @MainActor private func launchCompact() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-compact-layout", "--ui-testing-duo-layout",
            "--ui-testing-duo-autoplay-probe", "--ui-testing-duo-long-playback",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        waitForValue("\"layout\":\"compact\"", in: layout)
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        waitForValue("\"title\":\"Layout Track 1\"", in: playback)
        waitForValue("\"playing\":true", in: playback)
        return app
    }

    @MainActor private func assertInfoCommandDoesNotPresent(in app: XCUIApplication) {
        app.typeKey("i", modifierFlags: .command)
        XCTAssertFalse(app.buttons["Close"].firstMatch.exists)
        waitForValue("\"infoItemID\":\"\"", in: duoDiagnostic("duoSessionMetrics", in: app))
    }

    @MainActor private func selectedItemID(in app: XCUIApplication) throws -> String {
        let selection = duoDiagnostic("duoSelectionMetrics", in: app)
        let value = try XCTUnwrap(selection.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        let metrics = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let selected = try XCTUnwrap(metrics["selectedItemID"] as? String)
        XCTAssertFalse(selected.isEmpty)
        return selected
    }

    @MainActor private func track(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'phoneTrack.' AND label CONTAINS %@", title
        )).firstMatch
    }

    @MainActor private func tab(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.tabBars.buttons[title]
        return button.exists ? button : app.buttons[title].firstMatch
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

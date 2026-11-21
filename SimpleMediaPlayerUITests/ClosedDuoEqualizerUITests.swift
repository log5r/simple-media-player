#if os(iOS)
import UIKit
import XCTest

/// Command+Option+E opens the equalizer on the Duo's Closed display, in the library and in the deck.
final class ClosedDuoEqualizerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone layout.")
    }

    /// Select the Duo's Closed posture in Device Hub before running this case.
    @MainActor func testEqualizerCommandOpensTheLibraryAndDeckSheets() throws {
        let app = launch()
        try skipUnlessClosedDuo(app)
        let equalizer = app.navigationBars["Equalizer"]

        app.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertTrue(equalizer.waitForExistence(timeout: 5), "The library's equalizer sheet")
        assertHorizontalToolbar(equalizer, button: sheetCloseButton(in: app), name: "Library equalizer")
        attachScreenshot(in: app, name: "Library equalizer")
        app.typeKey("e", modifierFlags: [.command, .option])
        waitForDisappearance(equalizer)

        openDeck(in: app)
        app.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertTrue(equalizer.waitForExistence(timeout: 5), "The deck's equalizer sheet")
        assertHorizontalToolbar(equalizer, button: sheetCloseButton(in: app), name: "Deck equalizer")
        attachScreenshot(in: app, name: "Deck equalizer")
        app.typeKey("e", modifierFlags: [.command, .option])
        waitForDisappearance(equalizer)
        app.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertTrue(equalizer.waitForExistence(timeout: 5), "The deck's equalizer sheet reopens")
        sheetCloseButton(in: app).tap()
        waitForDisappearance(equalizer)
        XCTAssertTrue(app.buttons["phoneDeckClose"].exists, "Closing the sheet keeps the deck")
    }

    /// The command cannot present the equalizer over another deck sheet, and the request is not kept for later.
    @MainActor func testEqualizerCommandDoesNothingOverTheDeckAdjustments() throws {
        let app = launch()
        try skipUnlessClosedDuo(app)
        openDeck(in: app)
        let equalizer = app.navigationBars["Equalizer"]
        let adjustments = app.navigationBars["Playback Adjustments"]
        let adjustmentClose = app.buttons["phoneAdjustmentClose"]

        app.buttons["phoneLamp.EQ"].tap()
        XCTAssertTrue(adjustments.waitForExistence(timeout: 5))
        assertHorizontalToolbar(adjustments, button: adjustmentClose, name: "Playback adjustments")
        attachScreenshot(in: app, name: "Deck playback adjustments")
        app.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertFalse(equalizer.waitForExistence(timeout: 2), "No equalizer over the adjustments")
        adjustmentClose.tap()
        waitForDisappearance(adjustments)
        XCTAssertFalse(equalizer.waitForExistence(timeout: 2), "The dropped request does not open it later")

        // The dropped request left the sheet hidden, so the next command shows it rather than hiding it.
        app.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertTrue(equalizer.waitForExistence(timeout: 5), "The deck's equalizer sheet")
        sheetCloseButton(in: app).tap()
        waitForDisappearance(equalizer)
    }

    /// The Info page presents its artwork preview itself, so the deck learns of it only through a preference.
    @MainActor func testEqualizerCommandDoesNothingOverTheDeckArtworkPreview() throws {
        let app = launch(extraArguments: ["--ui-testing-artwork"])
        try skipUnlessClosedDuo(app)
        openDeck(in: app)
        let equalizer = app.navigationBars["Equalizer"]
        // Library rows behind the deck also show images labeled "Artwork".
        let preview = app.images["artworkPreviewImage"]

        app.buttons["phonePage.Info"].tap()
        let enlarge = app.buttons["Enlarge Artwork"]
        XCTAssertTrue(enlarge.waitForExistence(timeout: 10), "The Info page shows the fixture's artwork")
        // The scaled artwork can extend below the card, so tap near its top, which follows the index row.
        enlarge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "The artwork preview")
        attachScreenshot(in: app, name: "Deck artwork preview")
        app.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertFalse(equalizer.waitForExistence(timeout: 2), "No equalizer over the artwork preview")
        sheetCloseButton(in: app).tap()
        waitForDisappearance(preview)
        XCTAssertFalse(equalizer.waitForExistence(timeout: 2), "The dropped request does not open it later")

        app.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertTrue(equalizer.waitForExistence(timeout: 5), "The deck's equalizer sheet")
        sheetCloseButton(in: app).tap()
        waitForDisappearance(equalizer)
    }

    @MainActor private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-compact-layout", "--ui-testing-duo-layout",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["All Songs"].waitForExistence(timeout: 10))
        // The Simulator drops the first key event after each launch, even after waiting or tapping.
        // An unassigned key absorbs it so the commands under test are delivered.
        app.typeKey(.F19, modifierFlags: [])
        return app
    }

    @MainActor private func skipUnlessClosedDuo(_ app: XCUIApplication) throws {
        let element = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let value = try XCTUnwrap(element.value as? String)
        let geometry = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(value.data(using: .utf8))) as? [String: Any]
        )
        let safeArea = geometry["safeArea"] as? [String: Double] ?? [:]
        try XCTSkipUnless(
            geometry["horizontalSizeClass"] as? String == "compact"
                && geometry["portrait"] as? Bool == true
                && (safeArea["leading", default: 0] + safeArea["trailing", default: 0]) > 0,
            "Run this case on the Duo's Closed display."
        )
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

    /// The Close button of a sheet or the artwork preview. The deck's own Close button stays in the tree under it.
    @MainActor private func sheetCloseButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == 'Close' AND identifier != 'phoneDeckClose'")).firstMatch
    }

    /// The sheet keeps a horizontal toolbar: its button lies inside the navigation bar.
    @MainActor private func assertHorizontalToolbar(_ bar: XCUIElement, button: XCUIElement, name: String) {
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(name) close button")
        let barFrame = bar.frame
        let buttonFrame = button.frame
        XCTAssertGreaterThan(barFrame.width, barFrame.height, "\(name) navigation bar is horizontal")
        XCTAssertGreaterThanOrEqual(buttonFrame.minY, barFrame.minY - 1, "\(name) close button top")
        XCTAssertLessThanOrEqual(buttonFrame.maxY, barFrame.maxY + 1, "\(name) close button bottom")
    }

    @MainActor private func waitForDisappearance(_ element: XCUIElement) {
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
    }

    @MainActor private func attachScreenshot(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif

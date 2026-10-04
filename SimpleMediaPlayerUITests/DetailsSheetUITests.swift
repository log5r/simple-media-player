#if os(iOS)
import UIKit
import XCTest

final class DetailsSheetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testInformationSelectionSurvivesDetailsDismissal() throws {
        let app = try launchExpanded()
        let sheet = openDetails(in: app)
        selectContent("Info", in: app)
        let information = informationButton(in: app)
        XCTAssertTrue(information.waitForExistence(timeout: 10))
        waitForEnabled(information)

        dismissDetails(sheet, in: app)
        waitForDisappearance(sheet)

        let session = duoDiagnostic("duoSessionMetrics", in: app)
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        waitForValue("\"panelContent\":\"information\"", in: session)
        waitForValue("\"showsDetails\":false", in: session)

        _ = openDetails(in: app)

        let picker = duoDiagnostic("lyricsPanelContentPicker", in: app)
        XCTAssertTrue(picker.buttons["Info"].isSelected)
        XCTAssertTrue(information.waitForExistence(timeout: 10))
        waitForEnabled(information)
    }

    @MainActor func testInformationAndLyricsEditorsReturnToDetails() throws {
        let app = try launchExpanded()
        _ = openDetails(in: app)
        selectContent("Info", in: app)
        let information = informationButton(in: app)
        XCTAssertTrue(information.waitForExistence(timeout: 10))
        waitForEnabled(information)
        information.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        waitForDisappearance(close)
        XCTAssertTrue(duoDiagnostic("libraryDetailsSheet", in: app).waitForExistence(timeout: 5))
        waitForEnabled(information)

        selectContent("Lyrics", in: app)
        let lyrics = app.buttons["Edit Lyrics…"].firstMatch
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap()
        let editor = app.textViews["Lyrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.buttons["Cancel"].firstMatch.tap()
        waitForDisappearance(editor)

        XCTAssertTrue(duoDiagnostic("libraryDetailsSheet", in: app).waitForExistence(timeout: 5))
        let picker = duoDiagnostic("lyricsPanelContentPicker", in: app)
        XCTAssertTrue(picker.buttons["Lyrics"].isSelected)
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
    }

    @MainActor func testDetailsCommandsToggleSheetAtAccessibilityTextSize() throws {
        try requireIPadCommandDelivery()
        let app = try launchExpanded()
        showLibraryForCommands(in: app)
        for _ in 0..<2 {
            app.typeKey("l", modifierFlags: [.command, .option])
            let sheet = duoDiagnostic("libraryDetailsSheet", in: app)
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            app.typeKey("l", modifierFlags: [.command, .option])
            waitForDisappearance(sheet)
        }
    }

    @MainActor func testEqualizerCommandsToggleSheetAtAccessibilityTextSize() throws {
        try requireIPadCommandDelivery()
        let app = try launchExpanded()
        showLibraryForCommands(in: app)
        for _ in 0..<2 {
            app.typeKey("e", modifierFlags: [.command, .option])
            let sheet = app.navigationBars["Equalizer"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            app.typeKey("e", modifierFlags: [.command, .option])
            waitForDisappearance(sheet)
        }
    }

    @MainActor func testDetailsToolbarReopensSheetAtAccessibilityTextSize() throws {
        let app = try launchExpanded()
        showLibraryForCommands(in: app)
        for _ in 0..<2 {
            let sheet = openDetails(in: app)
            dismissDetails(sheet, in: app)
            waitForDisappearance(sheet)
        }
    }

    @MainActor func testEqualizerToolbarReopensSheetAtAccessibilityTextSize() throws {
        let app = try launchExpanded()
        showLibraryForCommands(in: app)
        for _ in 0..<2 {
            let button = app.buttons["equalizerButton"].firstMatch
            if button.exists && button.isHittable {
                button.tap()
            } else {
                let overflow = app.buttons["BottomOverflowBarButtonItem"]
                XCTAssertTrue(overflow.waitForExistence(timeout: 5))
                overflow.tap()
                app.buttons["Equalizer"].firstMatch.tap()
            }
            let sheet = app.navigationBars["Equalizer"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            sheet.buttons["Close"].tap()
            waitForDisappearance(sheet)
        }
    }

    @MainActor private func requireIPadCommandDelivery() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .pad,
            "Shortcut UI is verified on iPad. Phone simulator did not deliver existing Import or Mute commands."
        )
    }

    @MainActor private func showLibraryForCommands(in app: XCUIApplication) {
        let library = app.buttons["duoShowLibrary"]
        if library.exists { library.tap() }
        let track = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'libraryTrack.'")
        ).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 10))
    }

    @MainActor private func launchExpanded() throws -> XCUIApplication {
        if ProcessInfo.processInfo.environment["DUO_INTERACTIVE_ORIENTATION_TESTS"] != "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-duo-autoplay-probe",
            "--ui-testing-duo-long-playback", "--ui-testing-phone-large-text",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        // The Duo simulator may keep its display in portrait after XCTest requests landscape.
        if ProcessInfo.processInfo.environment["DUO_INTERACTIVE_ORIENTATION_TESTS"] != "1",
           (layout.value as? String)?.contains("\"portrait\":true") == true {
            XCUIDevice.shared.orientation = .portrait
        }
        try XCTSkipIf(
            (layout.value as? String)?.contains("\"layout\":\"expanded\"") != true,
            "This test requires an expanded iPad or iPhone Duo layout."
        )
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        waitForValue("\"title\":\"Layout Track 1\"", in: playback)
        let pause = app.buttons["pauseButton"]
        if pause.exists && pause.isHittable {
            pause.tap()
            waitForValue("\"paused\":true", in: playback)
        }
        return app
    }

    @MainActor private func openDetails(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["lyricsButton"].firstMatch
        if button.exists && button.isHittable {
            button.tap()
        } else {
            let overflow = app.buttons["BottomOverflowBarButtonItem"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 5))
            overflow.tap()
            let details = app.buttons["Details"].firstMatch
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            details.tap()
        }
        let sheet = duoDiagnostic("libraryDetailsSheet", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        return sheet
    }

    @MainActor private func selectContent(_ title: String, in app: XCUIApplication) {
        let picker = duoDiagnostic("lyricsPanelContentPicker", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        let button = picker.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    @MainActor private func dismissDetails(_ sheet: XCUIElement, in app: XCUIApplication) {
        if app.otherElements["PopoverDismissRegion"].firstMatch.exists {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let outside: CGVector
            if sheet.frame.minX > app.frame.minX + 24 {
                outside = CGVector(
                    dx: sheet.frame.minX - app.frame.minX - 16, dy: sheet.frame.midY - app.frame.minY
                )
            } else {
                let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
                XCTAssertTrue(dismissRegion.isHittable, dismissRegion.debugDescription)
                dismissRegion.tap()
                return
            }
            origin.withOffset(outside).tap()
        } else {
            let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            let end = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }

    @MainActor private func informationButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Edit Information…"].firstMatch
    }

    @MainActor private func waitForEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element
        )
        wait(for: [expectation], timeout: 10)
    }

    @MainActor private func waitForDisappearance(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        wait(for: [expectation], timeout: 10)
    }

    @MainActor private func waitForValue(_ value: String, in element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", value), object: element
        )
        wait(for: [expectation], timeout: 10)
    }
}
#endif

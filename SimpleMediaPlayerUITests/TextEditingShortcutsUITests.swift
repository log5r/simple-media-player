#if os(macOS)
import XCTest

/// ⌘← / ⌘→ / ⌥← / ⌥→ / ⌘↑ / ⌘↓ are also playback and volume menu shortcuts.
/// While a text field is being edited they must move the caret and leave the player alone.
final class TextEditingShortcutsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGetInfoTextFieldUsesTextNavigationKeysInsteadOfMenuShortcuts() throws {
        let app = launch()
        defer { cleanUpSaveFiles(in: app) }
        let middleRow = app.descendants(matching: .any)["mediaRow.2"]
        XCTAssertTrue(middleRow.waitForExistence(timeout: 5))
        middleRow.click()
        // With a middle row selected, Previous/Next Track are enabled and would start playback of a neighbor.
        for identifier in ["previousTrackButton", "nextTrackButton"] {
            waitFor("enabled == true", app.buttons[identifier])
        }
        let stop = app.buttons["stopButton"]
        XCTAssertFalse(stop.isEnabled)
        let volume = app.buttons["volumeDownButton"]
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        let originalVolume = try XCTUnwrap(volume.value as? String)

        app.typeKey("i", modifierFlags: .command)
        let title = app.textFields["Title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        waitFor("enabled == true", title, timeout: 10)
        title.click()
        app.typeKey("a", modifierFlags: .command)
        // The space also checks that the unmodified play/pause shortcut does not take typed spaces.
        app.typeText("ab c")
        waitForValue("ab c", of: title)

        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeText("X")
        waitForValue("Xab c", of: title)
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeText("Y")
        waitForValue("Xab cY", of: title)
        app.typeKey(.leftArrow, modifierFlags: .option)
        app.typeText("Z")
        waitForValue("Xab ZcY", of: title)
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeText("1")
        waitForValue("1Xab ZcY", of: title)
        app.typeKey(.rightArrow, modifierFlags: .option)
        app.typeText("2")
        waitForValue("1Xab2 ZcY", of: title)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("3")
        waitForValue("1Xab2 ZcY3", of: title)

        let sheetClose = app.sheets.buttons["Close"]
        (sheetClose.exists ? sheetClose : app.buttons["Close"].firstMatch).click()
        let discard = app.windows.buttons["Close Without Saving"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.click()
        waitFor("exists == false", title, timeout: 3)

        XCTAssertFalse(stop.isEnabled, "⌘← or ⌘→ started playback through Previous or Next Track")
        XCTAssertEqual(volume.value as? String, originalVolume, "⌘↑ or ⌘↓ changed the volume")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // The delayed-save fixture backs the tracks with real tagged files, so their text tags are editable.
        app.launchArguments = [
            "--ui-testing-multiple-selection", "--ui-testing-media-count=3", "--ui-testing-delayed-metadata-save",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES", "-bottomPanelLayout", "classic"
        ]
        app.launch()
        app.activate()
        let anchor = app.buttons["addPlaylistButton"]
        if !anchor.waitForExistence(timeout: 5) { app.typeKey("n", modifierFlags: .command) }
        XCTAssertTrue(anchor.waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func cleanUpSaveFiles(in app: XCUIApplication) {
        app.terminate()
        app.launchArguments = [
            "--ui-testing-multiple-selection", "--ui-testing-media-count=1", "--ui-testing-cleanup-metadata-save"
        ]
        app.launch()
        app.terminate()
    }

    @MainActor
    private func waitForValue(
        _ value: String, of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [reached], timeout: 3), .completed,
            "Expected \(value), found \(element.value ?? "nil")", file: file, line: line
        )
    }

    @MainActor
    private func waitFor(
        _ format: String, _ element: XCUIElement, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: timeout), .completed, format, file: file, line: line)
    }
}
#endif

import XCTest

#if os(iOS)
import UIKit
#endif

final class BulkMetadataEditabilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testClosingDuringEditabilityCheckAndReopeningAnotherSelection() {
        let app = launch()
        openEditor(for: [1, 2], in: app)

        let progress = app.descendants(matching: .any)["bulkMetadataEditabilityProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        let summary = app.staticTexts["bulkEditSelectionSummary"]
        XCTAssertEqual(summary.value as? String, "2")
        XCTAssertFalse(app.buttons["bulkEditApplyButton"].isEnabled)

        let close = app.buttons["bulkEditCloseButton"]
        XCTAssertTrue(close.isEnabled)
        let startedClosing = Date()
        press(close)
        waitForDisappearance(close, timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(startedClosing), 5, "Closing waited for the slow file check")

        openEditor(for: [3], in: app)
        #if os(macOS)
        let title = app.checkBoxes["bulkEditField.title"]
        #else
        let title = app.switches["bulkEditField.title"]
        #endif
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 3), .completed)
        XCTAssertEqual(summary.value as? String, "1")
        XCTAssertFalse(progress.exists)
        press(close)
        waitForDisappearance(close, timeout: 3)
    }

    @MainActor
    func testStoppingASaveKeepsTheRemainingFilesAndModelsUnchanged() {
        let app = launch(delayedSave: true)
        defer { cleanUpSaveFiles(in: app) }
        openEditor(for: [1, 2, 3], in: app)
        #if os(macOS)
        let title = app.checkBoxes["bulkEditField.title"]
        #else
        let title = app.switches["bulkEditField.title"]
        #endif
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 5), .completed)
        press(title)
        let field = app.textFields["Title"]
        press(field)
        field.typeText("Stopped bulk title")
        press(app.buttons["bulkEditApplyButton"])

        let progress = app.descendants(matching: .any)["bulkEditProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let secondFile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Applying 2 of 3…")).firstMatch
        XCTAssertTrue(secondFile.waitForExistence(timeout: 5))
        let stop = app.buttons["bulkEditStopButton"]
        reveal(stop, in: app.scrollViews["bulkEditScrollView"])
        XCTAssertTrue(stop.isEnabled)
        press(stop)
        let resultText = "1 files updated, 2 not processed (cancelled)."
        let result = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", resultText, resultText)
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        waitForDisappearance(stop, timeout: 3)
        let storedTitles = app.staticTexts["bulkEditSavedFileTitles"]
        let expectedFileTitles = "Stopped bulk title|UI Test Track 2|UI Test Track 3"
        let filesAreCorrect = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", expectedFileTitles, expectedFileTitles),
            object: storedTitles
        )
        XCTAssertEqual(XCTWaiter.wait(for: [filesAreCorrect], timeout: 5), .completed)

        closeWithoutApplying(in: app)
        for expectedTitle in ["Stopped bulk title", "UI Test Track 2", "UI Test Track 3"] {
            let modelRow = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@ OR value == %@", expectedTitle, expectedTitle)
            ).firstMatch
            XCTAssertTrue(modelRow.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    private func closeWithoutApplying(in app: XCUIApplication) {
        press(app.buttons["bulkEditCloseButton"])
        #if os(macOS)
        let discard = app.windows.buttons["Close Without Applying"]
        #else
        let discard = app.buttons["Close Without Applying"]
        #endif
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        press(discard)
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
    private func launch(delayedSave: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-multiple-selection", "--ui-testing-media-count=3",
            delayedSave ? "--ui-testing-delayed-metadata-save" : "--ui-testing-delayed-editability",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES", "-bottomPanelLayout", "classic"
        ]
        app.launch()
        #if os(macOS)
        app.activate()
        let anchor = app.buttons["addPlaylistButton"]
        if !anchor.waitForExistence(timeout: 5) { app.typeKey("n", modifierFlags: .command) }
        XCTAssertTrue(anchor.waitForExistence(timeout: 15))
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let allSongs = app.buttons["All Songs"]
            XCTAssertTrue(allSongs.waitForExistence(timeout: 15))
            allSongs.tap()
        } else {
            XCTAssertTrue(app.buttons["addPlaylistButton"].waitForExistence(timeout: 15))
        }
        #endif
        return app
    }

    @MainActor
    private func openEditor(for trackNumbers: [Int], in app: XCUIApplication) {
        var multipleEdit = app.buttons["multipleEditButton"]
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            multipleEdit = app.openToolbarOverflowMenu(item: "Select")
        }
        #endif
        XCTAssertTrue(multipleEdit.waitForExistence(timeout: 5))
        press(multipleEdit)
        for number in trackNumbers {
            let title = "UI Test Track \(number)"
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            press(row)
        }
        let editSelected = app.buttons["editSelectedMediaButton"]
        XCTAssertTrue(editSelected.waitForExistence(timeout: 5))
        let expectedLabel = "Edit Selected, \(trackNumbers.count) selected"
        let countIsAccessible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expectedLabel), object: editSelected
        )
        XCTAssertEqual(XCTWaiter.wait(for: [countIsAccessible], timeout: 3), .completed)
        press(editSelected)
        XCTAssertTrue(app.buttons["bulkEditCloseButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<3 {
            if scrollView.frame.contains(element.frame), !element.frame.isEmpty { break }
            scrollView.swipeUp()
        }
        let controlFrame = element.frame
        XCTAssertFalse(controlFrame.isEmpty)
        XCTAssertFalse(controlFrame.isInfinite)
        XCTAssertTrue(scrollView.frame.contains(controlFrame), "Control remains outside the scroll viewport")
    }

    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) {
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: timeout), .completed)
    }
}

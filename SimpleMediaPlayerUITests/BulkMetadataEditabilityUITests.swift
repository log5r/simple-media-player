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
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-multiple-selection", "--ui-testing-media-count=3",
            "--ui-testing-delayed-editability",
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
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let more = app.buttons["phoneTrackMore"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
        }
        #endif
        let multipleEdit = app.buttons["multipleEditButton"]
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
        waitForValue(String(trackNumbers.count), of: editSelected)
        press(editSelected)
        XCTAssertTrue(app.buttons["bulkEditCloseButton"].waitForExistence(timeout: 5))
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
    private func waitForValue(_ value: String, of element: XCUIElement) {
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 3), .completed)
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) {
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: timeout), .completed)
    }
}

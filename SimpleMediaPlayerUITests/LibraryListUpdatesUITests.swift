import XCTest

#if os(iOS)
import UIKit
#endif

final class LibraryListUpdatesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLargeLibrarySortingSearchingAndSelection() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-multiple-selection", "--ui-testing-media-count=3000",
            "--ui-testing-library-search=UI Test Track 299",
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
            XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 15))
            app.tabBars.buttons["Search"].tap()
        } else {
            XCTAssertTrue(app.buttons["addPlaylistButton"].waitForExistence(timeout: 15))
        }
        #endif

        sort(by: "Title", in: app)
        sort(by: "Artist", in: app)
        let search = searchField(in: app)
        waitForValue("UI Test Track 299", of: search)
        dismissSearchKeyboard(in: app)
        let first = track(number: 2990, in: app)
        let second = track(number: 2991, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 10))

        beginMultipleSelection(in: app)
        press(first)
        press(second)
        let selected = app.buttons["editSelectedMediaButton"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        waitForValue("2", of: selected)
        endMultipleSelection(in: app)

        refineSearch(in: app)
        XCTAssertTrue(track(number: 2999, in: app).waitForExistence(timeout: 10))
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        verifySearchAfterChangingTabs(in: app)
    }

    @MainActor
    private func verifySearchAfterChangingTabs(in app: XCUIApplication) {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.tabBars.buttons["Library"].tap()
            app.tabBars.buttons["Search"].tap()
            XCTAssertTrue(track(number: 2999, in: app).waitForExistence(timeout: 10))
            waitForValue("UI Test Track 2999", of: app.searchFields.firstMatch)
        }
        #endif
    }

    @MainActor
    private func searchField(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad, field.exists == false {
            // The tablet toolbar collapses searchable into a Search button when space is limited.
            let activateSearch = app.buttons["Search"].firstMatch
            XCTAssertTrue(activateSearch.waitForExistence(timeout: 5))
            activateSearch.tap()
        }
        #endif
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }

    @MainActor
    private func refineSearch(in app: XCUIApplication) {
        let search = searchField(in: app)
        press(search)
        #if os(macOS)
        app.typeKey(.rightArrow, modifierFlags: .command)
        #else
        // The seeded query is shorter than the field; tap its trailing blank space.
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        #endif
        search.typeText("9")
        dismissSearchKeyboard(in: app)
    }

    @MainActor
    private func sort(by field: String, in app: XCUIApplication) {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let more = app.buttons["phoneTrackMore"]
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
            // iOS presents these Picker choices directly in the More menu.
            XCTAssertTrue(app.buttons[field].waitForExistence(timeout: 5))
            app.buttons[field].tap()
            return
        }
        #endif
        let header = app.buttons[field].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        press(header)
    }

    @MainActor
    private func beginMultipleSelection(in app: XCUIApplication) {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { app.buttons["phoneTrackMore"].tap() }
        #endif
        let multipleEdit = app.buttons["multipleEditButton"]
        XCTAssertTrue(multipleEdit.waitForExistence(timeout: 5))
        press(multipleEdit)
    }

    @MainActor
    private func endMultipleSelection(in app: XCUIApplication) {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.buttons["Done"].tap()
            return
        }
        #endif
        press(app.buttons["cancelMultipleEditButton"])
    }

    @MainActor
    private func track(number: Int, in app: XCUIApplication) -> XCUIElement {
        let title = "UI Test Track \(number)"
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)).firstMatch
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
    private func dismissSearchKeyboard(in app: XCUIApplication) {
        #if os(iOS)
        let submit = app.keyboards.buttons["Search"]
        if submit.exists { submit.tap() }
        #endif
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement) {
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
    }
}

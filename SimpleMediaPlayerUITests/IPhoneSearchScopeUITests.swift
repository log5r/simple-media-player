#if os(iOS)
import UIKit
import XCTest

final class IPhoneSearchScopeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies phone search scope.")
    }

    @MainActor func testQueryDoesNotFilterLibraryGroupsOrPlaylists() {
        let app = launch()
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Layout Track 2")
        dismissSearchKeyboard(in: app)
        verifySearchResult(in: app)

        verifyUnfilteredDestinations(in: app)

        app.tabBars.buttons["Search"].tap()
        verifySearchResult(in: app)
        XCTAssertEqual(search.value as? String, "Layout Track 2")
    }

    @MainActor func testAdvancedFilterDoesNotFilterLibraryGroupsOrPlaylists() {
        let app = launch()
        app.tabBars.buttons["Search"].tap()
        let filters = app.buttons["advancedSearchButton"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Layout Track 2")
        app.buttons["advancedSearchDoneButton"].tap()
        verifySearchResult(in: app)

        verifyUnfilteredDestinations(in: app)

        app.tabBars.buttons["Search"].tap()
        verifySearchResult(in: app)
        filters.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Layout Track 2")
    }

    @MainActor private func verifyUnfilteredDestinations(in app: XCUIApplication) {
        app.tabBars.buttons["Library"].tap()
        app.buttons["All Songs"].tap()
        verifyAllTracks(in: app)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Albums"].tap()
        let album = app.buttons["libraryGroup.albums.Layout Album"]
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        album.tap()
        verifyAllTracks(in: app)

        app.tabBars.buttons["Playlists"].tap()
        app.buttons["Layout Playlist"].tap()
        verifyAllTracks(in: app)
    }

    @MainActor private func verifyAllTracks(in app: XCUIApplication) {
        for number in 1...3 {
            XCTAssertTrue(track(number, in: app).waitForExistence(timeout: 10))
        }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'"))
        XCTAssertEqual(rows.count, 3)
    }

    @MainActor private func verifySearchResult(in app: XCUIApplication) {
        XCTAssertTrue(track(2, in: app).waitForExistence(timeout: 10))
        for number in [1, 3] {
            let absent = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: track(number, in: app)
            )
            wait(for: [absent], timeout: 10)
        }
    }

    @MainActor private func track(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'"))
            .containing(.staticText, identifier: "Layout Track \(number)").firstMatch
    }

    @MainActor private func dismissSearchKeyboard(in app: XCUIApplication) {
        let submit = app.keyboards.buttons["search"]
        if submit.exists { submit.tap() }
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-compact-layout",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["phoneLibraryMore"].waitForExistence(timeout: 10))
        return app
    }
}
#endif

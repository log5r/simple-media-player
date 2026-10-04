#if os(iOS)
import UIKit
import XCTest

final class ExpandedGroupFilteringUITests: XCTestCase {
    private var expandedHeight = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "This suite verifies expanded iPad group filtering.")
    }

    @MainActor func testAlbumQueryPreservesItsRouteAndBulkSelectionWhenTracksAreHidden() throws {
        let app = try launchExpanded()
        openGroup(section: "albums", name: "Layout Album", otherName: "Other Album", in: app)
        let bulkIDs = try beginBulkSelection(in: app)

        // Track 3 keeps the projection nonempty; the second query empties the entire projection.
        for query in ["Layout Track 3", "No matching track"] {
            setQuery(query, in: app)
            try verifyEmptyGroup(section: "albums", name: "Layout Album", otherName: "Other Album", in: app)
            try verifyBulkSelection(bulkIDs, in: app)

            setQuery("", in: app)
            try verifyRestoredGroup(section: "albums", name: "Layout Album", in: app)
            try verifyBulkSelection(bulkIDs, in: app)
        }
    }

    @MainActor func testAlbumAdvancedFilterPreservesItsRouteWhenTracksAreHidden() throws {
        let app = try launchExpanded()
        openGroup(section: "albums", name: "Layout Album", otherName: "Other Album", in: app)

        setTitleFilter("Layout Track 3", in: app)
        try verifyEmptyGroup(section: "albums", name: "Layout Album", otherName: "Other Album", in: app)

        clearFilters(in: app)
        try verifyRestoredGroup(section: "albums", name: "Layout Album", in: app)
    }

    @MainActor func testArtistAndGenreQueriesPreserveTheirRoutesWhenTracksAreHidden() throws {
        let app = try launchExpanded()
        for (section, name, otherName) in [
            ("artists", "Layout Artist", "Other Artist"), ("genres", "No Genre", "Other Genre")
        ] {
            openGroup(section: section, name: name, otherName: otherName, in: app)
            for query in ["Layout Track 3", "No matching track"] {
                setQuery(query, in: app)
                try verifyEmptyGroup(section: section, name: name, otherName: otherName, in: app)

                setQuery("", in: app)
                try verifyRestoredGroup(section: section, name: name, in: app)
            }
            app.buttons["libraryGroupBackButton"].tap()
        }
    }

    @MainActor private func launchExpanded() throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-multiple-albums",
            "--ui-testing-reset-led-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-volumeNormalizationEnabled", "NO", "-showEqualizerPanel", "NO", "-showLyricsPanel", "NO"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let geometry = try metrics(layout)
        XCTAssertEqual(geometry["layout"] as? String, "expanded")
        expandedHeight = Int(try XCTUnwrap(geometry["height"] as? Double))
        XCTAssertTrue(duoDiagnostic("duoBrowsingMetrics", in: app).waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func openGroup(section: String, name: String, otherName: String, in app: XCUIApplication) {
        let category = duoDiagnostic("sidebarLibraryRow.\(section)", in: app)
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        let group = app.buttons["libraryGroup.\(section).\(name)"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["libraryGroup.\(section).\(otherName)"].waitForExistence(timeout: 10))
        group.tap()
        XCTAssertTrue(app.buttons["libraryGroupBackButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(track(1, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(track(2, in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(track(3, in: app).exists)
    }

    @MainActor private func setQuery(_ query: String, in app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        if !search.exists {
            let reveal = app.buttons["Search"].firstMatch
            XCTAssertTrue(reveal.waitForExistence(timeout: 5))
            reveal.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if let current = search.value as? String, current.isEmpty == false, current != search.placeholderValue {
            let clear = search.buttons.firstMatch
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
            clear.tap()
        }
        if query.isEmpty == false {
            search.tap()
            search.typeText(query)
        }
        dismissKeyboard(in: app)
        waitForValue(query.isEmpty ? "\"search\":\"\"" : "\"search\":\"\(query)\"",
                     in: duoDiagnostic("duoSearchMetrics", in: app))
    }

    @MainActor private func setTitleFilter(_ title: String, in app: XCUIApplication) {
        toolbarButton(identifier: "advancedSearchButton", title: "Filters", in: app).tap()
        let field = app.textFields["Title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(title, in: field, app: app)
        dismissKeyboard(in: app)
        let done = app.buttons["advancedSearchDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        waitForFilterDismissal(in: app)
        waitForValue("\"title\":\"\(title)\"", in: duoDiagnostic("duoSearchMetrics", in: app))
    }

    @MainActor private func clearFilters(in app: XCUIApplication) {
        toolbarButton(identifier: "advancedSearchButton", title: "Filters", in: app).tap()
        let clear = app.buttons["clearFiltersButton"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        app.buttons["advancedSearchDoneButton"].tap()
        waitForFilterDismissal(in: app)
        waitForValue("\"title\":\"\"", in: duoDiagnostic("duoSearchMetrics", in: app))
    }

    @MainActor private func replaceText(_ text: String, in field: XCUIElement, app: XCUIApplication) {
        let currentValue = field.value as? String ?? ""
        let hasText = currentValue.isEmpty == false && currentValue != field.placeholderValue
        field.tap()
        if hasText { app.typeKey("a", modifierFlags: .command) }
        if text.isEmpty == false {
            field.typeText(text)
        } else if hasText {
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
    }

    @MainActor private func waitForFilterDismissal(in app: XCUIApplication) {
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        let done = app.buttons["advancedSearchDoneButton"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: done
        )
        wait(for: [expectation], timeout: 10)
    }

    @MainActor private func dismissKeyboard(in app: XCUIApplication) {
        // The system key can appear as a button without a Keyboard parent in the AX tree.
        let hide = app.buttons["Hide keyboard"].firstMatch
        if hide.waitForExistence(timeout: 2) {
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: hide)
            wait(for: [hittable], timeout: 5)
            hide.tap()
            waitForDisappearance(hide)
        }
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        let minimumHeight = Double(expandedHeight) * 0.9
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = layout.value as? String, let data = value.data(using: .utf8),
                  let geometry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let height = geometry["height"] as? Double else { return false }
            return height >= minimumHeight
        }, object: nil)
        wait(for: [restored], timeout: 10)
    }

    @MainActor private func verifyEmptyGroup(
        section: String, name: String, otherName: String, in app: XCUIApplication
    ) throws {
        waitForDisappearance(track(1, in: app))
        waitForDisappearance(track(2, in: app))
        try verifyRoute(section: section, name: name, in: app)
        XCTAssertTrue(app.staticTexts["No Media"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["libraryGroupBackButton"].exists, "An empty projection must retain Back to List.")
        XCTAssertFalse(track(3, in: app).exists, "Filtering must not switch to the other group's track.")
        XCTAssertFalse(app.buttons["libraryGroup.\(section).\(otherName)"].exists)
    }

    @MainActor private func verifyRestoredGroup(section: String, name: String, in app: XCUIApplication) throws {
        try verifyRoute(section: section, name: name, in: app)
        XCTAssertTrue(track(1, in: app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(track(2, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["libraryGroupBackButton"].exists)
        XCTAssertFalse(track(3, in: app).exists)
        XCTAssertFalse(app.staticTexts["No Media"].firstMatch.exists)
        try verifyRoute(section: section, name: name, in: app)
    }

    @MainActor private func verifyRoute(section: String, name: String, in app: XCUIApplication) throws {
        let browsing = try metrics(duoDiagnostic("duoBrowsingMetrics", in: app))
        XCTAssertEqual(browsing["groupSection"] as? String, section)
        XCTAssertEqual(browsing["groupName"] as? String, name)
        XCTAssertEqual(browsing["selection"] as? String, "library.\(section)")
        XCTAssertEqual(browsing["libraryPath"] as? [String], ["section.\(section)", "group.\(section).\(name)"])
        XCTAssertEqual(browsing["tab"] as? Int, 0)
    }

    @MainActor private func beginBulkSelection(in app: XCUIApplication) throws -> [String] {
        toolbarButton(identifier: "multipleEditButton", title: "Multiple Edit", in: app).tap()
        let first = track(1, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        let selection = duoDiagnostic("duoSelectionMetrics", in: app)
        waitForValue("\"isBulkEditing\":true", in: selection)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: first)
        wait(for: [selected], timeout: 10)
        let bulkIDs = try XCTUnwrap(try metrics(selection)["bulkIDs"] as? [String])
        XCTAssertEqual(bulkIDs.count, 1)
        return bulkIDs
    }

    @MainActor private func verifyBulkSelection(_ expectedIDs: [String], in app: XCUIApplication) throws {
        let selection = try metrics(duoDiagnostic("duoSelectionMetrics", in: app))
        XCTAssertEqual(selection["isBulkEditing"] as? Bool, true)
        XCTAssertEqual(selection["bulkIDs"] as? [String], expectedIDs)
    }

    @MainActor private func toolbarButton(identifier: String, title: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        if button.exists && button.isHittable { return button }
        let overflow = app.buttons["BottomOverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 5))
        overflow.tap()
        if button.waitForExistence(timeout: 2) { return button }
        let menuItem = app.buttons[title].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        return menuItem
    }

    @MainActor private func track(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'libraryTrack.' AND label CONTAINS %@", "Layout Track \(number)"
        )).firstMatch
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

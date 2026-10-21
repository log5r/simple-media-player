#if os(iOS)
import UIKit
import XCTest

/// Run in Device Hub's Open posture; each case skips unless the real orientation matches.
/// Thirty extra tracks make the list taller than the Library, so its last row reaches the bottom controls.
final class DuoLibraryOverlapUITests: XCTestCase {
    private let lastIndex = 33

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the Duo library layout.")
    }

    @MainActor func testPortraitListKeepsItsColumnsAndLastRowAboveSearch() throws {
        let app = try launch(portrait: true)
        app.buttons["duoShowLibrary"].tap()
        let close = app.buttons["duoCloseLibrary"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(track(index: 1, in: app).waitForExistence(timeout: 10))
        // The 669pt list would leave 429pt beside the details column, so Lyrics opens in a sheet instead.
        XCTAssertFalse(app.buttons["text.quote"].exists, "The portrait list must not show the inline details column.")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        // The floating search field must leave the list's last row reachable above it.
        let last = try scrollToLastRow(in: app, from: 0.6, to: 0.25, above: search.frame.minY)
        XCTAssertLessThanOrEqual(search.frame.maxY, close.frame.minY)
        assertTapSelects(last, in: app)
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.buttons["duoShowLibrary"].waitForExistence(timeout: 5))
    }

    @MainActor func testLandscapeSearchAndColumnsStayClearOfSidebarAndToolbar() throws {
        let app = try launch(portrait: false)
        let first = track(index: 1, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let filters = app.buttons["advancedSearchButton"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        // The vertical toolbar has no room for search, so it sits below the title instead of over the sidebar rows.
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebarLibraryRow.'")).allElementsBoundByIndex
        XCTAssertFalse(rows.isEmpty)
        for row in rows { XCTAssertFalse(row.frame.intersects(search.frame), row.identifier) }
        XCTAssertLessThanOrEqual(search.frame.maxX, filters.frame.minX)
        XCTAssertLessThanOrEqual(search.frame.maxY, first.frame.minY)

        // The list's trailing safe area keeps the last columns readable beside the vertical toolbar.
        let titleHeader = app.buttons["Title"].firstMatch
        XCTAssertTrue(titleHeader.exists)
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: filters.frame.minX - 40, dy: titleHeader.frame.maxY + 66))
        for _ in 0..<2 { start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -500, dy: 0))) }
        for title in ["Genre", "Time"] {
            let header = app.buttons[title].firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 5), title)
            XCTAssertLessThanOrEqual(header.frame.maxX, filters.frame.minX, title)
        }
        let sidebar = app.descendants(matching: .any)["librarySidebar"]
        XCTAssertTrue(sidebar.exists)
        // The playback panel starts where the Library's columns end.
        assertTapSelects(try scrollToLastRow(in: app, from: 0.5, to: 0.25, above: sidebar.frame.maxY), in: app)
    }

    @MainActor private func launch(portrait: Bool) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout",
            "--ui-testing-multiple-selection", "--ui-testing-media-count=30", "-showLyricsPanel", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let geometry = try metrics(layout)
        try XCTSkipIf((geometry["division"] as? [[String: Any]] ?? []).isEmpty, "Run on iPhone Duo in Device Hub.")
        try XCTSkipUnless(geometry["portrait"] as? Bool == portrait, "Select the case's orientation in Device Hub.")
        try XCTSkipIf(geometry["hasActiveDivision"] as? Bool == true, "Select the Open posture in Device Hub.")
        XCTAssertEqual(geometry["layout"] as? String, "expanded")
        return app
    }

    @MainActor private func track(index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'libraryTrack.' AND label BEGINSWITH %@", "\(index), ")
        ).firstMatch
    }

    /// Drags between normalized window heights until the list stops with its last row above `limit`.
    @MainActor private func scrollToLastRow(
        in app: XCUIApplication, from startY: CGFloat, to endY: CGFloat, above limit: CGFloat
    ) throws -> XCUIElement {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        let last = track(index: lastIndex, in: app)
        var previous = CGRect.null
        for _ in 0..<12 {
            start.press(forDuration: 0.05, thenDragTo: end)
            // A tap during the bounce only stops scrolling, so let the list come to rest first.
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "Scrolling settles")], timeout: 1)
            if last.exists, last.frame == previous {
                XCTAssertLessThanOrEqual(last.frame.maxY, limit, "The last row stopped behind \(limit): \(last.frame)")
                return last
            }
            previous = last.exists ? last.frame : .null
        }
        XCTFail("The list did not settle at its last row: \(last.frame)")
        return last
    }

    /// Checks only that the tap reached the row; the extra fixture tracks have no playable files.
    @MainActor private func assertTapSelects(_ row: XCUIElement, in app: XCUIApplication) {
        let itemID = row.identifier.dropFirst("libraryTrack.".count)
        // Element taps in Duo's landscape window can land rows above the target, so tap the window point a user would.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: row.frame.midY)).tap()
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "\"itemID\":\"\(itemID)\""), object: playback
        )], timeout: 10)
        XCTAssertEqual(result, .completed, "The tap did not reach \(row.label).")
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let data = try XCTUnwrap((element.value as? String)?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
#endif

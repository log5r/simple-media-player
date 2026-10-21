#if os(iOS)
import XCTest

extension XCTestCase {
    /// A search without results replaces the list, and clearing it builds a new one from the saved row.
    @MainActor func recreateLibraryList(in app: XCUIApplication, rows: XCUIElementQuery) {
        var field = app.searchFields.firstMatch
        if field.exists == false {
            let activateSearch = app.buttons["Search"].firstMatch
            XCTAssertTrue(activateSearch.waitForExistence(timeout: 5))
            activateSearch.tap()
            field = app.searchFields.firstMatch
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zzz")
        let emptied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [emptied], timeout: 10), .completed)
        field.buttons["Clear text"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
    }

    /// The saved scroll row, as the accessibility identifier its row has with `prefix`.
    @MainActor func savedScrollItemID(in app: XCUIApplication, prefix: String) -> String {
        let metrics = duoDiagnostic("duoSelectionMetrics", in: app)
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (value CONTAINS %@)", "\"scrollItemID\":\"\""), object: metrics
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        let json = Data((metrics.value as? String ?? "").utf8)
        let values = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        return "\(prefix)\(values?["scrollItemID"] as? String ?? "")"
    }
}
#endif

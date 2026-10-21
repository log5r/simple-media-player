#if os(iOS)
import UIKit
import XCTest

/// The expanded iOS library table pins its one-row column header over the rows.
final class LibraryTableHeaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if UIDevice.current.userInterfaceIdiom == .phone { XCUIDevice.shared.orientation = .portrait }
        super.tearDown()
    }

    /// Restoring the first row used to align it with the viewport top, beneath the header.
    @MainActor func testLongLibraryOpensWithFirstRowBelowHeader() throws {
        let table = try launchTable()
        let first = table.rows.matching(NSPredicate(format: "label BEGINSWITH %@", "1, ")).firstMatch
        XCTAssertTrue(first.exists)
        XCTAssertEqual(first.frame.minY, table.header.frame.maxY, accuracy: 1, "Row 1 must open below the header")
    }

    @MainActor func testSavedRowIsRestoredBelowHeader() throws {
        let table = try launchTable()
        let (app, rows, header) = (table.app, table.rows, table.header)
        try scrollTable(rows: rows, below: header, in: app)
        let saved = savedScrollItemID(in: app, prefix: "libraryTrack.")
        let visible = rows.allElementsBoundByIndex
            .filter { $0.frame.maxY > header.frame.maxY + 0.5 }
            .min { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(saved, visible?.identifier, "The saved row must be the first one visible below the header")

        recreateLibraryList(in: app, rows: rows)
        let restored = rows.matching(identifier: saved).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(
            restored.frame.minY, header.frame.maxY, accuracy: 1, "The restored row must sit below the header"
        )
    }

    /// Opens a 60-track library in the expanded table, turning a compact iPhone to landscape when needed.
    @MainActor private func launchTable() throws -> LibraryTable {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-multiple-selection", "--ui-testing-media-count=60", "--ui-testing-duo-layout",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "libraryTrack.")
        )
        if rows.firstMatch.waitForExistence(timeout: 15) == false,
           UIDevice.current.userInterfaceIdiom == .phone {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 10), "The expanded library table is not shown.")
        let header = app.buttons.matching(NSPredicate(format: "label == %@", "Title")).firstMatch
        XCTAssertTrue(header.exists)
        return LibraryTable(app: app, rows: rows, header: header)
    }

    /// Drag rows up by several rows, using window points because Duo element taps can land on another row.
    @MainActor private func scrollTable(
        rows: XCUIElementQuery, below header: XCUIElement, in app: XCUIApplication
    ) throws {
        let startY = header.frame.maxY + 250
        let start = rows.allElementsBoundByIndex.first { $0.frame.minY <= startY && startY < $0.frame.maxY }
        try XCTSkipUnless(start?.isHittable == true, "Too few rows are visible to scroll by several rows.")
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: header.frame.midX, dy: startY)).press(
            forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: header.frame.midX, dy: header.frame.maxY + 40))
        )
    }
}

private struct LibraryTable {
    let app: XCUIApplication
    let rows: XCUIElementQuery
    let header: XCUIElement
}
#endif

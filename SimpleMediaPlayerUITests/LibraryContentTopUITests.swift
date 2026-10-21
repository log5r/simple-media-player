#if os(iOS)
import UIKit
import XCTest

/// Long iPad library lists without a saved row open at their content top, above the first track.
final class LibraryContentTopUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "This suite verifies the expanded iPad library.")
    }

    /// Restoring the first track used to scroll the back button and album header off screen.
    @MainActor func testAlbumDetailOpensAtBackButton() throws {
        let app = launch()
        open(section: "albums", in: app)
        let album = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "libraryGroup.albums.")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        album.tap()

        let first = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "libraryTrack.", "1,")
        ).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let back = app.buttons["libraryGroupBackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(back.frame.minY, 0, "The back button must open on screen")
        XCTAssertTrue(back.isHittable, "The back button must open on screen")
        XCTAssertGreaterThan(first.frame.minY, back.frame.maxY + 100, "The album header must stay above track 1")
    }

    /// The first section header of a grouped list must not cover or replace its first row.
    @MainActor func testGroupedListOpensAtFirstSectionHeader() throws {
        let app = launch()
        open(section: "artists", in: app)
        let header = app.buttons["libraryGroup.artists.UI Test Artist"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let first = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "1, UI Test Track 1,")
        ).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(header.isHittable, "The section header must open on screen")
        XCTAssertGreaterThanOrEqual(
            first.frame.minY, header.frame.maxY - 1, "Track 1 must open below its section header"
        )
    }

    /// The list's coordinate space includes rows hidden under the navigation bar and the pinned section header.
    @MainActor func testGroupedListSavesFirstRowBelowSectionHeader() throws {
        let app = launch()
        open(section: "artists", in: app)
        let header = app.buttons["libraryGroup.artists.UI Test Artist"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "libraryGroupedTrack.")
        )
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))

        // Drag about six rows up, using window points as `LibraryTableHeaderUITests` does.
        let rowHeight = rows.firstMatch.frame.height
        let startY = header.frame.maxY + rowHeight * 7
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: header.frame.midX, dy: startY)).press(
            forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: header.frame.midX, dy: startY - rowHeight * 6))
        )
        let saved = savedScrollItemID(in: app, prefix: "libraryGroupedTrack.")
        let visible = rows.allElementsBoundByIndex
            .filter { $0.frame.maxY > header.frame.maxY + 0.5 }
            .min { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(
            saved, visible?.identifier, "The saved row must be the first one visible below the section header"
        )

        recreateLibraryList(in: app, rows: rows)
        let restored = rows.matching(identifier: saved).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(
            restored.frame.minY, header.frame.maxY, accuracy: 1, "The restored row must sit below the section header"
        )
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-multiple-selection", "--ui-testing-media-count=60", "--ui-testing-duo-layout",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        return app
    }

    @MainActor private func open(section: String, in app: XCUIApplication) {
        let category = duoDiagnostic("sidebarLibraryRow.\(section)", in: app)
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        category.tap()
    }
}
#endif

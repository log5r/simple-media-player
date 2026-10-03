import XCTest
#if os(iOS)
import UIKit
#endif

final class LibraryArtworkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(macOS)
    @MainActor
    func testLegacyAndStoredArtworkSurviveAlbumNavigation() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "--ui-testing-media-count=2",
            "--ui-testing-artwork",
            "-ApplePersistenceIgnoreState", "YES",
            "-mediaListColumnCustomization", "",
            "-bottomPanelLayout", "classic"
        ]
        app.launch()
        app.activate()
        let mainWindowAnchor = app.buttons["addPlaylistButton"]
        if !mainWindowAnchor.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(mainWindowAnchor.waitForExistence(timeout: 10))

        // Both rows must decode: the first starts in the legacy column and requires
        // the preparation gate; the second already has a separate artwork record.
        selectLibrarySection("allSongs", in: app)
        assertLoadedArtworkCount(2, in: app)
        attachScreenshot(of: app, named: "Artwork in track list")

        selectLibrarySection("albums", in: app)
        let legacyAlbum = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "UI Test Legacy Artwork")
        ).firstMatch
        XCTAssertTrue(legacyAlbum.waitForExistence(timeout: 5))
        assertLoadedArtworkCount(2, in: app)
        attachScreenshot(of: app, named: "Artwork in album grid")

        selectLibrarySection("allSongs", in: app)
        let albumDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: legacyAlbum
        )
        XCTAssertEqual(XCTWaiter.wait(for: [albumDisappeared], timeout: 5), .completed)
        assertLoadedArtworkCount(2, in: app)
        attachScreenshot(of: app, named: "Artwork after returning to track list")
    }

    @MainActor
    private func selectLibrarySection(_ section: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .outlineRow)
            .containing(.any, identifier: "sidebarLibraryRow.\(section)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 40, dy: 0)).click()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }
    #endif

    #if os(iOS)
    @MainActor
    func testLegacyAndStoredArtworkSurvivePhoneNavigation() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This test verifies the phone layout.")
        let app = launchArtworkFixture()
        let allSongs = app.buttons["All Songs"]
        XCTAssertTrue(allSongs.waitForExistence(timeout: 10))
        allSongs.tap()
        XCTAssertTrue(app.buttons["phoneTrackMore"].waitForExistence(timeout: 5))
        assertLoadedArtworkCount(2, in: app)
        attachScreenshot(of: app, named: "Artwork in phone track list")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["phoneLibraryMore"].waitForExistence(timeout: 5))
        let trackListDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["phoneTrackMore"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [trackListDisappeared], timeout: 5), .completed)
        allSongs.tap()
        XCTAssertTrue(app.buttons["phoneTrackMore"].waitForExistence(timeout: 5))
        assertLoadedArtworkCount(2, in: app)
        attachScreenshot(of: app, named: "Artwork after returning to phone track list")
    }

    @MainActor
    func testLegacyAndStoredArtworkLoadInTabletRows() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "This test verifies the tablet layout.")
        let app = launchArtworkFixture()
        XCTAssertTrue(app.buttons["addPlaylistButton"].waitForExistence(timeout: 10))
        // The tablet starts on All Songs and uses the shared list rather than the phone navigation stack.
        XCTAssertTrue(app.staticTexts["UI Test Track 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI Test Track 2"].waitForExistence(timeout: 5))
        assertLoadedArtworkCount(2, in: app)
        attachScreenshot(of: app, named: "Artwork in tablet track list")
    }

    @MainActor
    private func launchArtworkFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-multiple-selection",
            "--ui-testing-media-count=2",
            "--ui-testing-artwork",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-mediaListColumnCustomization", "",
            "-mediaListVisibleColumns", "index,artwork,title,artist",
            "-mediaListColumnOrder", "index,artwork,title,artist",
            "-bottomPanelLayout", "classic"
        ]
        app.launch()
        return app
    }
    #endif

    @MainActor
    private func assertLoadedArtworkCount(_ expected: Int, in app: XCUIApplication) {
        #if os(macOS)
        // Album artwork is exposed as part of its combined button on macOS.
        let artwork = app.descendants(matching: .any).matching(identifier: "libraryArtworkImage")
        #else
        // Tablet row buttons inherit the identifier as well, so count only their child images.
        let artwork = app.images.matching(identifier: "libraryArtworkImage")
        #endif
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in artwork.count == expected }, object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertEqual(artwork.count, expected)
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

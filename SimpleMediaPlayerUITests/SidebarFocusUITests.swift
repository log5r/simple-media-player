import XCTest

final class SidebarFocusUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLibraryRowClicksMoveKeyboardFocusFromTrackList() {
        let app = launchApp()
        let artists = row(containing: "sidebarLibraryRow.artists", in: app)
        let genres = row(containing: "sidebarLibraryRow.genres", in: app)
        XCTAssertTrue(artists.waitForExistence(timeout: 3))
        XCTAssertTrue(genres.waitForExistence(timeout: 3))
        click(artists, at: .content)

        // Repeat both hit regions after giving the track list keyboard focus each time.
        for location in [RowClickLocation.trailingWhitespace, .content, .trailingWhitespace, .content] {
            focusTrackList(in: app)
            click(genres, at: location)
            waitForSelection(of: genres)

            // Selection alone also succeeds with the regression. An arrow key must
            // move the sidebar selection, proving the click transferred focus.
            app.typeKey(.upArrow, modifierFlags: [])
            waitForSelection(of: artists)
            XCTAssertFalse(genres.isSelected)
        }
    }

    @MainActor
    func testPlaylistRowClicksMoveKeyboardFocusFromTrackList() {
        let app = launchApp()
        let addPlaylistButton = app.buttons["addPlaylistButton"]
        let playlists = app.descendants(matching: .outlineRow).containing(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebarPlaylistRow.")
        )

        addPlaylistButton.click()
        XCTAssertTrue(playlists.element(boundBy: 0).waitForExistence(timeout: 3))
        addPlaylistButton.click()
        XCTAssertTrue(playlists.element(boundBy: 1).waitForExistence(timeout: 3))
        XCTAssertEqual(playlists.count, 2)

        let firstPlaylist = playlists.element(boundBy: 0)
        let secondPlaylist = playlists.element(boundBy: 1)
        let artists = row(containing: "sidebarLibraryRow.artists", in: app)

        for location in [RowClickLocation.trailingWhitespace, .content] {
            click(artists, at: .content)
            waitForSelection(of: artists)
            focusTrackList(in: app)
            click(firstPlaylist, at: location)
            waitForSelection(of: firstPlaylist)

            app.typeKey(.downArrow, modifierFlags: [])
            waitForSelection(of: secondPlaylist)
            XCTAssertFalse(firstPlaylist.isSelected)
        }
    }

    @MainActor
    func testTableRowClickMovesKeyboardFocusFromSidebar() {
        let app = launchApp()
        let allSongs = row(containing: "sidebarLibraryRow.allSongs", in: app)
        let firstTrack = trackRow(number: 1, in: app)
        let secondTrack = trackRow(number: 2, in: app)

        click(allSongs, at: .content)
        waitForSelection(of: allSongs)
        firstTrack.click()
        waitForSelection(of: firstTrack)

        // A selected table row can stay gray when the sidebar retains keyboard focus.
        app.typeKey(.downArrow, modifierFlags: [])
        waitForSelection(of: secondTrack)
        XCTAssertTrue(allSongs.isSelected)
    }

    private enum RowClickLocation {
        case content
        case trailingWhitespace
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "--ui-testing-media-count=3",
            "-ApplePersistenceIgnoreState", "YES",
            "-bottomPanelLayout", "classic"
        ]
        app.launch()
        app.activate()
        let mainWindowAnchor = app.buttons["addPlaylistButton"]
        if !mainWindowAnchor.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(mainWindowAnchor.waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func row(containing identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .outlineRow).containing(.any, identifier: identifier).firstMatch
    }

    @MainActor
    private func click(_ row: XCUIElement, at location: RowClickLocation) {
        let xOffset: CGFloat
        switch location {
        case .content:
            xOffset = 40
        case .trailingWhitespace:
            xOffset = row.frame.width - 24
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: xOffset, dy: 0))
            .click()
    }

    @MainActor
    private func focusTrackList(in app: XCUIApplication) {
        let firstTrack = trackRow(number: 1, in: app)
        firstTrack.click()
    }

    @MainActor
    private func trackRow(number: Int, in app: XCUIApplication) -> XCUIElement {
        // These titles come from the in-memory fixture, independently of the app's
        // language. Three tracks also keep Track 1 distinct from Track 10.
        let title = "UI Test Track \(number)"
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)
        let rows = app.descendants(matching: .outlineRow)
        let labeledRow = rows.matching(predicate).firstMatch
        let rowContainingLabel = rows.containing(predicate).firstMatch
        let appeared = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in labeledRow.exists || rowContainingLabel.exists },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 3), .completed)
        return labeledRow.exists ? labeledRow : rowContainingLabel
    }

    @MainActor
    private func waitForSelection(
        of row: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: row
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selected], timeout: 3),
            .completed,
            "The expected row did not become selected",
            file: file,
            line: line
        )
    }
}

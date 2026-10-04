#if os(iOS)
import UIKit
import XCTest

/// These cases verify the expanded browsing operations. Device Hub supplies the Open posture.
/// Closed/Open transitions are additionally inspected using duoBrowsingMetrics and duoEditorMetrics.
final class DuoBrowsingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies Duo browsing.")
    }

    @MainActor func testAlbumArtistAndGenreGroupsPlayAndReturnToTheirCategory() throws {
        let app = try launchExpanded()
        for (section, name) in [("albums", "Layout Album"), ("artists", "Layout Artist"), ("genres", "No Genre")] {
            let category = element("sidebarLibraryRow.\(section)", in: app)
            XCTAssertTrue(category.waitForExistence(timeout: 5))
            category.tap()
            let group = element("libraryGroup.\(section).\(name)", in: app)
            XCTAssertTrue(group.waitForExistence(timeout: 10))
            group.tap()
            let back = app.buttons["libraryGroupBackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            waitForValue("\"groupName\":\"\(name)\"", in: element("duoBrowsingMetrics", in: app))

            let track = track("Layout Track 2", in: app)
            XCTAssertTrue(track.waitForExistence(timeout: 5))
            track.tap()
            let playback = element("duoPlaybackMetrics", in: app)
            waitForValue("\"title\":\"Layout Track 2\"", in: playback)
            let before = try metrics(playback)
            XCTAssertEqual((before["queueIDs"] as? [String])?.count, 3)

            rotateDuo(to: .portrait, in: app)
            XCTAssertEqual(try metrics(element("duoBrowsingMetrics", in: app))["groupName"] as? String, name)
            XCTAssertEqual(try metrics(playback)["itemID"] as? String, before["itemID"] as? String)
            XCTAssertEqual(try metrics(playback)["queueIDs"] as? [String], before["queueIDs"] as? [String])
            rotateDuo(to: .landscapeLeft, in: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(group.waitForExistence(timeout: 5))
            waitForValue("\"groupName\":\"\"", in: element("duoBrowsingMetrics", in: app))
        }
    }

    @MainActor func testPlaylistReorderRemoveRenameAndDeleteKeepTheirTargets() throws {
        let app = try launchExpanded()
        let playlist = playlistRow("Layout Playlist", in: app)
        XCTAssertTrue(playlist.waitForExistence(timeout: 5), app.debugDescription)
        playlist.tap()
        let first = track("Layout Track 1", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let playback = element("duoPlaybackMetrics", in: app)
        waitForValue("\"title\":\"Layout Track 1\"", in: playback)
        let playingID = try metrics(playback)["itemID"] as? String
        // Freeze natural queue advancement while checking editing targets and ordering.
        app.buttons["pauseButton"].tap()
        waitForValue("\"paused\":true", in: playback)

        first.press(forDuration: 1)
        app.buttons["Move Down"].tap()
        let firstRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'libraryTrack.'")
        ).firstMatch
        waitForLabel("Layout Track 2", in: firstRow)
        XCTAssertEqual(try metrics(playback)["itemID"] as? String, playingID)

        let removed = track("Layout Track 3", in: app)
        removed.press(forDuration: 1)
        app.buttons["Remove from Playlist"].tap()
        let disappearance = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: removed
        )
        wait(for: [disappearance], timeout: 10)
        XCTAssertEqual(try metrics(playback)["itemID"] as? String, playingID)

        playlist.press(forDuration: 1)
        app.buttons["Rename"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" Renamed")
        app.alerts.buttons["Rename"].tap()
        let renamed = playlistRow("Layout Playlist Renamed", in: app)
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        renamed.press(forDuration: 1)
        app.buttons["Delete Playlist"].tap()
        app.alerts.buttons["Delete"].tap()
        waitForValue("\"selection\":\"library.allSongs\"", in: element("duoBrowsingMetrics", in: app))
        XCTAssertEqual(try metrics(element("duoBrowsingMetrics", in: app))["playlistPath"] as? [String], [])
        XCTAssertTrue(track("Layout Track 3", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(try metrics(playback)["itemID"] as? String, playingID)
    }

    @MainActor func testCompactPlaylistMovesTheDisplayedTrackAfterSearching() throws {
        let app = try launchExpanded(compact: true)
        let searchTab = tab("Search", in: app)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5), app.debugDescription)
        searchTab.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Layout Track 2")
        tab("Playlists", in: app).tap()
        app.buttons["Layout Playlist"].tap()
        let visible = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.' AND label CONTAINS 'Layout Track 2'")
        ).firstMatch
        XCTAssertTrue(visible.waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).count, 3
        )
        visible.press(forDuration: 1)
        app.buttons["Move Down"].tap()

        searchTab.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Layout Track 2".count))
        tab("Playlists", in: app).tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'"))
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 3)
        waitForLabel("Layout Track 1", in: rows.element(boundBy: 0))
        waitForLabel("Layout Track 3", in: rows.element(boundBy: 1))
        waitForLabel("Layout Track 2", in: rows.element(boundBy: 2))
    }

    @MainActor func testCompactPlaylistBackClearsTheExpandedDestination() throws {
        let app = try launchExpanded(compact: true)
        tab("Playlists", in: app).tap()
        app.buttons["Layout Playlist"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        waitForValue("\"selection\":\"playlist.", in: element("duoBrowsingMetrics", in: app))

        app.navigationBars.buttons.element(boundBy: 0).tap()

        let browsing = element("duoBrowsingMetrics", in: app)
        waitForValue("\"selection\":\"library.allSongs\"", in: browsing)
        XCTAssertEqual(try metrics(browsing)["playlistPath"] as? [String], [])
        XCTAssertEqual(try metrics(browsing)["tab"] as? Int, 1)
        XCTAssertTrue(app.buttons["Layout Playlist"].waitForExistence(timeout: 5))
    }

    @MainActor private func launchExpanded(compact: Bool = false) throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-reset-led-settings",
            "--ui-testing-duo-long-playback",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        if compact { app.launchArguments.append("--ui-testing-compact-layout") }
        app.launch()
        let layout = element("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        if compact == false { rotateDuo(to: .landscapeLeft, in: app) }
        let geometry = try metrics(layout)
        if compact == false {
            try XCTSkipIf(
                (geometry["division"] as? [[String: Any]] ?? []).isEmpty, "Select Duo's Open posture in Device Hub."
            )
        }
        XCTAssertEqual(geometry["layout"] as? String, compact ? "compact" : "expanded")
        XCTAssertTrue(element("duoBrowsingMetrics", in: app).waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func track(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'libraryTrack.' AND label CONTAINS %@", title)
        ).firstMatch
    }

    @MainActor private func playlistRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let sidebar = element("librarySidebar", in: app)
        for _ in 0..<4 {
            let row = matchingPlaylistRow(title, in: app)
            if row.exists && row.isHittable { return row }
            guard sidebar.exists else { return row }
            sidebar.swipeUp()
        }
        return matchingPlaylistRow(title, in: app)
    }

    @MainActor private func matchingPlaylistRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebarPlaylistRow.'")
        )
        if let row = rows.allElementsBoundByIndex.first(where: {
            $0.label.contains(title) || $0.staticTexts[title].exists
        }) { return row }
        let text = app.staticTexts[title].firstMatch
        if text.exists { return text }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor private func tab(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // Standard tabs can move into a vertical bar on a regular-width Duo screen.
        let button = app.buttons[title].firstMatch
        if button.exists { return button }
        return app.otherElements[title].firstMatch
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

    @MainActor private func waitForLabel(_ value: String, in element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", value), object: element
        )
        wait(for: [expectation], timeout: 10)
    }
}
#endif

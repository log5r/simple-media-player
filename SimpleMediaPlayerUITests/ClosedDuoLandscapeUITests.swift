#if os(iOS)
import UIKit
import XCTest

/// Select Closed landscape in Device Hub before running; XCTest rotation does not rotate the outer display.
final class ClosedDuoLandscapeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the Closed phone display.")
    }

    @MainActor func testDisplayShowsControlsBesideLEDWithoutScrolling() throws {
        let app = try launch()
        openDeck(in: app)
        let display = try regionFrame("phoneDeckCompactDisplayMetrics", in: app)
        let pages = try regionFrame("phoneDeckPageSwitcherMetrics", in: app)
        let seek = try regionFrame("phoneDeckSeekMetrics", in: app)
        XCTAssertTrue(app.frame.contains(display), "The LED plate must be visible without scrolling")
        XCTAssertGreaterThan(display.width, 200)
        XCTAssertGreaterThan(display.height, 200)
        XCTAssertLessThanOrEqual(display.maxY, pages.minY)
        XCTAssertLessThan(seek.maxX, display.minX, "The seek row belongs to the left controls column")
        for identifier in ["phoneStop", "phonePrevious", "phonePlayPause", "phoneNext", "phoneMute"] {
            let button = app.buttons[identifier]
            assertVisible(button, in: app)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertLessThan(button.frame.maxX, display.minX, identifier)
            XCTAssertLessThanOrEqual(button.frame.maxY, pages.minY, identifier)
        }
        for control in [app.sliders["Playback Position"], duoDiagnostic("volumeLevel", in: app)] {
            assertVisible(control, in: app)
            XCTAssertLessThan(control.frame.maxX, display.minX, control.identifier)
            XCTAssertLessThanOrEqual(control.frame.maxY, pages.minY, control.identifier)
        }
        let route = duoDiagnostic("phoneRoutePicker", in: app)
        assertVisible(route, in: app)
        XCTAssertEqual(route.frame.maxX, app.buttons["phoneNext"].frame.maxX, accuracy: 1)
        XCTAssertEqual(route.frame.minY, app.buttons["phoneMute"].frame.minY, accuracy: 1)
        XCTAssertEqual(display.minX - app.buttons["phoneNext"].frame.maxX, 16, accuracy: 1)
        attachScreenshot(in: app, name: "Closed landscape Display without scrolling")
    }

    @MainActor func testEnglishToolbarsKeepPrimaryActionsVisible() throws {
        try verifyToolbars(language: "en")
    }

    @MainActor func testJapaneseToolbarsKeepPrimaryActionsVisible() throws {
        try verifyToolbars(language: "ja")
    }

    /// Turn off Simulator's Connect Hardware Keyboard so this verifies the actual software keyboard geometry.
    @MainActor func testSearchKeepsFiltersVisibleAboveSoftwareKeyboard() throws {
        let app = try launch()
        tapTab("Search", in: app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Layout Track 2")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        try XCTSkipUnless(
            keyboard.frame.intersects(app.frame),
            "Disconnect the hardware keyboard in Simulator to verify software keyboard visibility."
        )
        let filters = app.navigationBarButton("Filters", timeout: 5)
        assertVisible(filters, in: app)
        XCTAssertLessThanOrEqual(filters.frame.maxY, keyboard.frame.minY, "The keyboard must not cover Filters")
        attachScreenshot(in: app, name: "Closed landscape Search with software keyboard")
        filters.tap()
        let done = app.buttons["advancedSearchDoneButton"]
        assertVisible(done, in: app)
        done.tap()
        waitForDisappearance(done)
        assertVisible(app.navigationBarButton("Filters", timeout: 5), in: app)
    }

    @MainActor private func verifyToolbars(language: String) throws {
        let app = try launch(language: language)
        let isJapanese = language == "ja"
        app.buttons[isJapanese ? "すべての曲" : "All Songs"].tap()
        verifySelectionToolbar(in: app, isJapanese: isJapanese)

        tapTab(isJapanese ? "プレイリスト" : "Playlists", in: app)
        app.buttons["Layout Playlist"].tap()
        let add = app.navigationBarButton(isJapanese ? "曲を追加" : "Add Tracks", timeout: 5)
        assertVisible(add, in: app)
        add.tap()
        let cancel = app.buttons[isJapanese ? "キャンセル" : "Cancel"]
        assertVisible(cancel, in: app)
        cancel.tap()
        waitForDisappearance(cancel)
        verifySelectionToolbar(in: app, isJapanese: isJapanese, addTracks: add)

        tapTab(isJapanese ? "検索" : "Search", in: app)
        let filters = app.navigationBarButton(isJapanese ? "フィルタ" : "Filters", timeout: 5)
        assertVisible(filters, in: app)
        filters.tap()
        let done = app.buttons["advancedSearchDoneButton"]
        assertVisible(done, in: app)
        done.tap()
        waitForDisappearance(done)

        tapTab(isJapanese ? "ライブラリ" : "Library", in: app)
        openDeck(in: app, opensAllSongs: false)
        verifyDeckToolbar(in: app, isJapanese: isJapanese)
    }

    @MainActor private func verifySelectionToolbar(
        in app: XCUIApplication, isJapanese: Bool, addTracks: XCUIElement? = nil
    ) {
        app.openToolbarOverflowMenu(item: isJapanese ? "選択" : "Select").tap()
        let done = app.navigationBarButton(isJapanese ? "完了" : "Done", timeout: 5)
        assertVisible(done, in: app)
        if let addTracks { assertVisible(addTracks, in: app) }
        attachScreenshot(in: app, name: "Closed landscape selection toolbar \(isJapanese ? "ja" : "en")")
        done.tap()
        XCTAssertTrue(app.toolbarOverflowButton().waitForExistence(timeout: 5))
    }

    @MainActor private func verifyDeckToolbar(in app: XCUIApplication, isJapanese: Bool) {
        let close = app.buttons["phoneDeckClose"]
        assertVisible(close, in: app)
        XCTAssertTrue(app.toolbarOverflowButton().waitForExistence(timeout: 5))
        app.buttons["phonePage.Lyrics"].tap()
        let edit = app.navigationBarButton(isJapanese ? "歌詞を編集…" : "Edit Lyrics…", timeout: 5)
        assertVisible(edit, in: app)
        assertVisible(close, in: app)
        attachScreenshot(in: app, name: "Closed landscape Lyrics toolbar \(isJapanese ? "ja" : "en")")
        edit.tap()
        let editor = app.textViews[isJapanese ? "歌詞" : "Lyrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons[isJapanese ? "キャンセル" : "Cancel"].tap()
        waitForDisappearance(editor)
        close.tap()
        waitForDisappearance(close)
        assertVisible(app.buttons["phoneLEDDock"], in: app)
    }

    @MainActor private func launch(language: String = "en") throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-duo-long-playback",
            "--ui-testing-reset-led-settings", "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let geometry = try metrics(layout)
        let width = try XCTUnwrap(geometry["width"] as? Double)
        let height = try XCTUnwrap(geometry["height"] as? Double)
        let safeArea = try XCTUnwrap(geometry["safeArea"] as? [String: Double])
        let screenWidth = width + safeArea["leading", default: 0] + safeArea["trailing", default: 0]
        let screenHeight = height + safeArea["top", default: 0] + safeArea["bottom", default: 0]
        let window = app.frame
        try XCTSkipUnless(
            geometry["horizontalSizeClass"] as? String == "compact"
                && geometry["portrait"] as? Bool == false
                && abs(window.width - 678) < 2 && abs(window.height - 466) < 2,
            "Select the 678 × 466 pt Closed landscape display in Device Hub before running."
        )
        XCTAssertEqual(geometry["layout"] as? String, "compact", "Use the real Closed layout without an override")
        XCTAssertEqual(window.width, screenWidth, accuracy: 1, "Content and safe area must fit the active display")
        XCTAssertEqual(window.height, screenHeight, accuracy: 1, "Content and safe area must fit the active display")
        return app
    }

    @MainActor private func openDeck(in app: XCUIApplication, opensAllSongs: Bool = true) {
        if opensAllSongs { app.buttons["All Songs"].tap() }
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        dock.tap()
        XCTAssertTrue(app.buttons["phoneDeckClose"].waitForExistence(timeout: 5))
    }

    @MainActor private func assertVisible(_ element: XCUIElement, in app: XCUIApplication) {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("Expected the control to appear in Closed landscape")
            return
        }
        XCTAssertTrue(element.isHittable, element.label)
        XCTAssertFalse(element.frame.isEmpty, element.label)
        XCTAssertTrue(app.frame.contains(element.frame), element.label)
    }

    @MainActor private func tapTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabButton(title, timeout: 5)
        attachScreenshot(in: app, name: "Closed landscape before switching to \(title)")
        if tab.exists, !tab.isHittable {
            // The vertical toolbar collapses tabs to the selected one when navigation items need the space.
            let bars = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "elementType == %lu", XCUIElement.ElementType.tabBar.rawValue),
                NSPredicate(format: "elementType == %lu", XCUIElement.ElementType.toolbar.rawValue)
            ])
            let titles = ["Library", "Playlists", "Videos", "Search", "ライブラリ", "プレイリスト", "ビデオ", "検索"]
            let selectedTabs = app.descendants(matching: .any).matching(bars).buttons.matching(
                NSPredicate(format: "(selected == true OR value == '1') AND label IN %@", titles)
            )
            guard let selected = selectedTabs.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
                XCTFail("The collapsed tabs must expose a selected tab that opens the tab chooser")
                return
            }
            assertVisible(selected, in: app)
            selected.tap()
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: tab)
            wait(for: [expanded], timeout: 5)
            attachScreenshot(in: app, name: "Closed landscape expanded tab chooser for \(title)")
        }
        assertVisible(tab, in: app)
        tab.tap()
    }

    @MainActor private func regionFrame(_ identifier: String, in app: XCUIApplication) throws -> CGRect {
        let element = duoDiagnostic(identifier, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let values = try metrics(element)
        return CGRect(
            x: try XCTUnwrap(values["x"] as? Double), y: try XCTUnwrap(values["y"] as? Double),
            width: try XCTUnwrap(values["width"] as? Double), height: try XCTUnwrap(values["height"] as? Double)
        )
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        let attachment = XCTAttachment(string: value)
        attachment.name = element.identifier
        attachment.lifetime = .keepAlways
        add(attachment)
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor private func waitForDisappearance(_ element: XCUIElement) {
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        wait(for: [disappeared], timeout: 5)
    }

    @MainActor private func attachScreenshot(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif

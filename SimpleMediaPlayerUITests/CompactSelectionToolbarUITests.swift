#if os(iOS)
import UIKit
import XCTest

/// Run in the current phone posture, including Duo Closed and both sides of Open Split View.
final class CompactSelectionToolbarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone selection toolbar.")
    }

    @MainActor func testSelectionToolbarFitsBesideTabsAndOpensEditor() throws {
        try verifySelectionToolbar(language: "en", accessibilityText: false)
    }

    @MainActor func testJapaneseSelectionToolbarFitsWithAccessibilityText() throws {
        try verifySelectionToolbar(language: "ja", accessibilityText: true)
    }

    @MainActor private func verifySelectionToolbar(language: String, accessibilityText: Bool) throws {
        let app = launch(language: language, accessibilityText: accessibilityText)
        let captureSize = app.screenshot().image.size
        let frameSize = app.frame.size
        try XCTSkipUnless(
            abs(captureSize.width / frameSize.width - captureSize.height / frameSize.height) < 0.01,
            "XCTest captures a different Duo display. Verify selection and editing in Device Hub."
        )
        let isJapanese = language == "ja"
        let allSongs = app.buttons[isJapanese ? "すべての曲" : "All Songs"]
        XCTAssertTrue(allSongs.waitForExistence(timeout: 10))
        allSongs.tap()
        let tracks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'"))
        XCTAssertTrue(tracks.element(boundBy: 1).waitForExistence(timeout: 10))
        tracks.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["phoneLEDDock"].waitForExistence(timeout: 10))
        app.openToolbarOverflowMenu(item: isJapanese ? "選択" : "Select").tap()
        let edit = app.buttons["editSelectedMediaButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(edit.isEnabled)
        tracks.element(boundBy: 0).tap()
        tracks.element(boundBy: 1).tap()
        let expectedLabel = isJapanese ? "選択した2件を編集" : "Edit Selected, 2 selected"
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ AND enabled == true", expectedLabel), object: edit
        )
        wait(for: [selected], timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Selection toolbar (\(language), accessibility text: \(accessibilityText))"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        assertSelectionControlsAreReachable(edit, in: app, isJapanese: isJapanese)

        verifyEditorAndSelectionReset(edit: edit, in: app, isJapanese: isJapanese)
    }

    @MainActor private func verifyEditorAndSelectionReset(
        edit: XCUIElement, in app: XCUIApplication, isJapanese: Bool
    ) {
        edit.tap()
        let close = app.buttons["bulkEditCloseButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["bulkEditSelectionSummary"].value as? String, "2")
        close.tap()
        XCTAssertTrue(app.toolbarOverflowButton().waitForExistence(timeout: 5))
        XCTAssertFalse(edit.exists)
        app.openToolbarOverflowMenu(item: isJapanese ? "選択" : "Select").tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(edit.isEnabled, "Closing the editor must clear its selection")
        app.buttons[isJapanese ? "完了" : "Done"].tap()
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: edit)
        wait(for: [disappeared], timeout: 5)
    }

    @MainActor private func assertSelectionControlsAreReachable(
        _ edit: XCUIElement, in app: XCUIApplication, isJapanese: Bool
    ) {
        XCTAssertTrue(edit.isHittable)
        XCTAssertGreaterThanOrEqual(edit.frame.width, 44)
        XCTAssertGreaterThanOrEqual(edit.frame.height, 44)
        XCTAssertTrue(app.frame.contains(edit.frame))
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.exists)
        // The selection button's AX frame includes its material extending into the bottom safe area.
        // Verify the visible controls and their actions; compare the bar's background in screenshots.
        for identifier in ["phoneLEDDock", "phoneDockPlayPause", "phoneDockNext"] {
            let control = app.buttons[identifier]
            if control.exists {
                XCTAssertTrue(control.isHittable, identifier)
                XCTAssertTrue(app.frame.contains(control.frame), identifier)
                XCTAssertLessThanOrEqual(edit.frame.minY + 44, control.frame.minY)
            }
        }
        let titles = isJapanese ? ["ライブラリ", "プレイリスト", "ビデオ", "検索"]
            : ["Library", "Playlists", "Videos", "Search"]
        for title in titles {
            let candidates = tabCandidates(title, in: app)
            let visible = candidates.filter { $0.isHittable && !$0.frame.isEmpty }
            XCTAssertFalse(visible.isEmpty, "Tab must remain accessible: \(title)")
        }
    }

    @MainActor private func tabCandidates(_ title: String, in app: XCUIApplication) -> [XCUIElement] {
        let predicate = NSPredicate(format: "label == %@", title)
        let tabs = app.descendants(matching: .tab).matching(predicate).allElementsBoundByIndex
        if tabs.isEmpty == false { return tabs }
        // Standard tabs can also appear as buttons or other elements when the Duo moves them to a vertical bar.
        let buttons = app.buttons.matching(predicate).allElementsBoundByIndex
        return buttons.isEmpty ? app.otherElements.matching(predicate).allElementsBoundByIndex : buttons
    }

    @MainActor private func launch(language: String, accessibilityText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-compact-layout", "--ui-testing-duo-long-playback",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            "-volumeNormalizationEnabled", "NO"
        ]
        if accessibilityText { app.launchArguments.append("--ui-testing-phone-large-text") }
        app.launch()
        return app
    }
}
#endif

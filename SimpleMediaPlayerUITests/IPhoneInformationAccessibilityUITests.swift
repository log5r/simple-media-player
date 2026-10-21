#if os(iOS)
import UIKit
import XCTest

final class IPhoneInformationAccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone layout.")
    }

    @MainActor func testEnglishInformationAtLargestAccessibilitySize() {
        verifyInformation(language: "en")
    }

    @MainActor func testJapaneseInformationAtLargestAccessibilitySize() {
        verifyInformation(language: "ja")
    }

    @MainActor private func verifyInformation(language: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-compact-layout", "--ui-testing-phone-large-text",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let allSongs = app.buttons[language == "ja" ? "すべての曲" : "All Songs"]
        XCTAssertTrue(allSongs.waitForExistence(timeout: 10))
        allSongs.tap()
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'"))
            .containing(.staticText, identifier: "Layout Track 1").firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        // Keep the chosen metadata stable while scrolling past the fixture's 60-second duration.
        app.buttons["phoneDockPlayPause"].tap()
        let paused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", language == "ja" ? "一時停止中" : "Paused"), object: track
        )
        wait(for: [paused], timeout: 5)
        dock.tap()
        guard let information = openInformation(in: app, language: language) else { return }
        let font = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        let values = [
            language == "ja" ? "アートワークがありません" : "No artwork available",
            "Layout Track 1", "Layout Artist", "Layout Album", "phone-layout-1.wav"
        ]
        for value in values {
            let text = information.staticTexts[value].firstMatch
            scrollTo(text, in: information)
            XCTAssertTrue(text.isHittable, "Information must remain reachable: \(value)")
            XCTAssertTrue(app.frame.contains(text.frame), "Information extends beyond the screen: \(value)")
            XCTAssertTrue(information.frame.contains(text.frame), "Information is clipped by the scroll view: \(value)")
            XCTAssertGreaterThanOrEqual(
                text.frame.height, font.lineHeight - 2,
                "Information must use the preferred body size: \(value)"
            )
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Information accessibility \(language) \(value)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        verifyEditingFromToolbar(in: app, language: language)
    }

    /// The deck has no bottom edit bars; Info edits from the More menu and Lyrics from the navigation bar.
    @MainActor private func verifyEditingFromToolbar(in app: XCUIApplication, language: String) {
        let editInformation = language == "ja" ? "情報を編集…" : "Edit Information…"
        app.openToolbarOverflowMenu(item: editInformation).tap()
        let close = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", language == "ja" ? "閉じる" : "Close", "phoneDeckClose"
        )).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Edit Information must open from the More menu")
        close.tap()
        XCTAssertTrue(app.buttons["phonePageMenu"].waitForExistence(timeout: 10))

        app.buttons["phonePageMenu"].tap()
        let lyricsPage = app.buttons["phonePage.Lyrics"]
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 5))
        lyricsPage.tap()
        let editLyrics = language == "ja" ? "歌詞を編集…" : "Edit Lyrics…"
        let addLyrics = language == "ja" ? "歌詞を追加…" : "Add Lyrics…"
        let navigationEdit = app.navigationBars.buttons[editLyrics]
        XCTAssertTrue(navigationEdit.waitForExistence(timeout: 5), "Edit Lyrics must stay in the navigation bar")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", editLyrics)).count, 1)
        XCTAssertFalse(app.buttons[addLyrics].exists, "The Lyrics page must not repeat the edit action at its bottom")
    }

    @MainActor private func openInformation(in app: XCUIApplication, language: String) -> XCUIElement? {
        let pageMenu = app.buttons["phonePageMenu"]
        XCTAssertTrue(pageMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(app.frame.contains(pageMenu.frame))
        pageMenu.tap()
        let informationPage = app.buttons["phonePage.Info"]
        XCTAssertTrue(informationPage.waitForExistence(timeout: 5))
        informationPage.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", language == "ja" ? "情報" : "Info"), object: pageMenu
        )
        wait(for: [selected], timeout: 5)
        let artwork = language == "ja" ? "アートワークがありません" : "No artwork available"
        guard app.staticTexts[artwork].waitForExistence(timeout: 10) else {
            let pageValue = String(describing: pageMenu.value)
            XCTFail("Info metadata did not load. Page value: \(pageValue)\n\(app.debugDescription)")
            return nil
        }
        // Once the metadata appears, the deck's only ScrollView is the Info content, not the old Display page.
        let single = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: app.scrollViews)
        wait(for: [single], timeout: 5)
        let information = app.scrollViews.firstMatch
        XCTAssertTrue(information.staticTexts[artwork].exists, "The Info scroll view must hold the metadata")
        let footer = app.buttons[language == "ja" ? "情報を編集…" : "Edit Information…"]
        XCTAssertFalse(footer.exists, "The Info page must not repeat the More menu's edit action at its bottom")
        return information
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in scrollView: XCUIElement) {
        let scrollFrame = scrollView.frame
        let visibleFrame = scrollFrame.insetBy(dx: 0, dy: 4)
        for _ in 0..<30 {
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            let hasFrame = exists && frame.height > 0
            if hasFrame, element.isHittable, visibleFrame.contains(frame) { return }
            if hasFrame, frame.height > visibleFrame.height {
                break
            }
            let scrollsDown = hasFrame && frame.minY < visibleFrame.minY
            let overflow = scrollsDown
                ? visibleFrame.minY - frame.minY
                : frame.maxY - visibleFrame.maxY
            let distance = hasFrame
                ? min(0.4, max(0.05, (overflow + 8) / scrollFrame.height))
                : 0.4
            let startY = scrollsDown ? 0.2 : 0.8
            let endY = startY + (scrollsDown ? distance : -distance)
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
            // Holding before release removes the momentum that can skip a large multiline value's visible range.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let exists = element.exists
        let frame = exists ? element.frame : .zero
        let label = exists ? element.label : "missing"
        let diagnostics = "Element: \(label), frame: \(frame), scroll view: \(scrollFrame), "
            + "visible: \(visibleFrame), hittable: \(exists && element.isHittable)"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = diagnostics
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Could not bring information fully into view. \(diagnostics)")
    }
}
#endif

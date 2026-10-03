#if os(iOS)
import UIKit
import XCTest

final class IPhoneEditorPickerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone layout.")
    }

    @MainActor func testEnglishLyricsOptionsAtLargestAccessibilitySize() {
        verifyLyricsOptions(language: "en")
    }

    @MainActor func testJapaneseLyricsOptionsAtLargestAccessibilitySize() {
        verifyLyricsOptions(language: "ja")
    }

    @MainActor func testEnglishFilterOptionsAtLargestAccessibilitySize() {
        verifyFilterOptions(language: "en")
    }

    @MainActor func testJapaneseFilterOptionsAtLargestAccessibilitySize() {
        verifyFilterOptions(language: "ja")
    }

    @MainActor private func launch(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL", "-AppleLanguages", "(\(language))",
            "-AppleLocale", language, "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["phoneLibraryMore"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func verifyLyricsOptions(language: String) {
        let app = launch(language: language)
        app.buttons[language == "ja" ? "すべての曲" : "All Songs"].tap()
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        dock.tap()
        app.buttons["phonePageMenu"].tap()
        let lyricsPage = app.buttons["phonePage.Lyrics"]
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 5))
        lyricsPage.tap()
        app.navigationBars.buttons[language == "ja" ? "歌詞を編集…" : "Edit Lyrics…"].firstMatch.tap()
        let editor = app.textViews[language == "ja" ? "歌詞" : "Lyrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(editor.frame.height, 100, "Lyrics must retain editable space")
        verifyOptions(
            [app.buttons["lyricsSaveLocation.applicationOnly"], app.buttons["lyricsSaveLocation.embeddedTag"]],
            in: app
        )
        let cancel = app.buttons[language == "ja" ? "キャンセル" : "Cancel"]
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.buttons["phoneDeckClose"].waitForExistence(timeout: 5))
    }

    @MainActor private func verifyFilterOptions(language: String) {
        let app = launch(language: language)
        app.tabBars.buttons[language == "ja" ? "検索" : "Search"].tap()
        let filters = app.buttons["advancedSearchButton"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        let done = app.buttons["advancedSearchDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.frame.contains(done.frame), "Done must remain on screen")
        verifyOptions([app.buttons["libraryFilterMatch.all"], app.buttons["libraryFilterMatch.any"]], in: app)
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
    }

    @MainActor private func verifyOptions(_ options: [XCUIElement], in app: XCUIApplication) {
        let font = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        for option in options {
            scrollTo(option, in: app)
            XCTAssertTrue(option.isHittable)
            XCTAssertTrue(app.frame.contains(option.frame), "Choice extends beyond the screen")
            let text = option.staticTexts[option.label]
            XCTAssertTrue(text.exists)
            let required = (option.label as NSString).boundingRect(
                with: CGSize(width: text.frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
            )
            XCTAssertGreaterThanOrEqual(text.frame.height, max(font.lineHeight, required.height) - 2)
            XCTAssertTrue(option.frame.contains(text.frame), "Choice text must fit")
        }
        options[1].tap()
        XCTAssertTrue(options[1].isSelected)
        XCTAssertFalse(options[0].isSelected)
        scrollTo(options[0], in: app, preferUp: true)
        options[0].tap()
        XCTAssertTrue(options[0].isSelected)
        XCTAssertFalse(options[1].isSelected)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, preferUp: Bool = false) {
        let matchingScrollView = app.scrollViews.containing(.button, identifier: element.identifier).firstMatch
        let scrollView = matchingScrollView.exists ? matchingScrollView : app.collectionViews.firstMatch
        let scrollFrame = scrollView.frame
        let visibleFrame = scrollFrame.intersection(app.frame.insetBy(dx: 8, dy: 80)).insetBy(dx: 0, dy: 4)
        for _ in 0..<24 {
            let frame = element.exists ? element.frame : .zero
            if frame.height > 0, element.isHittable, visibleFrame.contains(frame) { return }
            let scrollsUp = frame.height > 0 ? frame.minY < visibleFrame.minY : preferUp
            let overflow = scrollsUp ? visibleFrame.minY - frame.minY : frame.maxY - visibleFrame.maxY
            let distance = frame.height > 0 ? min(0.25, max(0.05, (overflow + 8) / scrollFrame.height)) : 0.25
            let startY = scrollsUp ? 0.3 : 0.8
            let endY = startY + (scrollsUp ? distance : -distance)
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let diagnostics = "\(element), frame: \(element.frame), viewport: \(visibleFrame)"
        XCTFail("Could not bring choice fully into view: \(diagnostics)")
    }
}
#endif

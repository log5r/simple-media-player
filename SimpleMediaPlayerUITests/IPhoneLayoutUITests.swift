#if os(iOS)
import UIKit
import XCTest

final class IPhoneLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone layout.")
    }

    @MainActor func testEnglishDarkDeck() {
        verifyDeck(language: "en", appearance: "dark", style: "dark")
    }

    @MainActor func testJapaneseLightBacklitDeck() {
        verifyDeck(language: "ja", appearance: "light", style: "backlit")
    }

    @MainActor func testEnglishLightDeck() {
        verifyDeck(language: "en", appearance: "light", style: "dark")
    }

    @MainActor func testJapaneseDarkBacklitDeck() {
        verifyDeck(language: "ja", appearance: "dark", style: "backlit")
    }

    @MainActor func testEnglishDockWithLongTitleAndLargeText() {
        verifyLargeTextDock(language: "en", appearance: "light")
    }

    @MainActor func testJapaneseDockWithLongTitleAndLargeText() {
        verifyLargeTextDock(language: "ja", appearance: "dark")
    }

    @MainActor func testEnglishDockWithLongTitleAndExtraLargeText() {
        verifyLargeTextDock(language: "en", appearance: "light", textArgument: "--ui-testing-phone-extra-large-text")
    }

    @MainActor private func launch(
        language: String, appearance: String, style: String, extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            "-appearanceMode", appearance, "-ledDisplayStyle", style,
            "-volumeNormalizationEnabled", "NO"
        ]
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    @MainActor private func verifyLargeTextDock(
        language: String, appearance: String, textArgument: String = "--ui-testing-phone-large-text"
    ) {
        let app = launch(language: language, appearance: appearance, style: "dark", extraArguments: [
            "--ui-testing-phone-long-title", textArgument
        ])
        let allSongs = app.buttons[language == "ja" ? "すべての曲" : "All Songs"]
        XCTAssertTrue(allSongs.waitForExistence(timeout: 10))
        allSongs.tap()
        let title = "とても長い曲名の表示確認 — A Very Long Track Name for Checking the Compact Playback Panel"
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'"))
            .containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        XCTAssertTrue((dock.value as? String)?.contains(title) == true, "VoiceOver needs the complete track title")
        verifyDock(in: app, name: "Dock long title \(textArgument) \(language)")
        let play = app.buttons["phoneDockPlayPause"]
        play.tap()
        XCTAssertEqual(play.label, language == "ja" ? "再生" : "Play")
        play.tap()
        XCTAssertEqual(play.label, language == "ja" ? "一時停止" : "Pause")
        let next = app.buttons["phoneDockNext"]
        next.tap()
        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Layout Track 2"), object: dock
        )
        wait(for: [advanced], timeout: 5)
        next.tap()
        let reachedEnd = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Layout Track 3"), object: dock
        )
        wait(for: [reachedEnd], timeout: 5)
        XCTAssertFalse(next.isEnabled, "Next must be disabled at the end of the queue")
        dock.tap()
        XCTAssertTrue(app.buttons["phoneDeckClose"].waitForExistence(timeout: 5))
    }

    @MainActor private func verifyDeck(language: String, appearance: String, style: String) {
        let app = launch(language: language, appearance: appearance, style: style)
        let allSongs = language == "ja" ? "すべての曲" : "All Songs"
        XCTAssertTrue(app.buttons[allSongs].waitForExistence(timeout: 10))
        app.buttons[allSongs].tap()
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        verifyDock(in: app, name: "Dock \(language) \(appearance) \(style)")
        dock.tap()
        XCTAssertTrue(app.buttons["phoneDeckClose"].waitForExistence(timeout: 5))
        attachScreenshot(in: app, name: "Deck \(language) \(appearance) \(style)")
        for id in ["phonePlayPause", "phonePrevious", "phoneNext", "phoneStop", "phoneLamp.KEY"] {
            assertTouchTarget(app.buttons[id], in: app)
        }
        let mute = app.buttons["phoneMute"]
        if !mute.isHittable { app.swipeUp() }
        assertTouchTarget(mute, in: app)
        XCTAssertEqual(mute.label, language == "ja" ? "ミュート" : "Mute")
        mute.tap()
        XCTAssertEqual(mute.label, language == "ja" ? "ミュート解除" : "Unmute")
        mute.tap()
        XCTAssertEqual(mute.label, language == "ja" ? "ミュート" : "Mute")
        app.buttons["phoneLamp.KEY"].tap()
        let close = app.buttons["phoneAdjustmentClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        app.buttons["phonePage.Lyrics"].tap()
        XCTAssertTrue(app.staticTexts["First lyric"].waitForExistence(timeout: 5))
        attachScreenshot(in: app, name: "Lyrics strip \(language) \(appearance) \(style)")
        app.buttons["phonePage.Info"].tap()
        XCTAssertTrue(app.buttons[language == "ja" ? "情報を編集…" : "Edit Information…"].waitForExistence(timeout: 5))
        app.buttons["phonePage.Up Next"].tap()
        XCTAssertTrue(app.staticTexts["Layout Track 3"].waitForExistence(timeout: 5))
        let queuedTrack = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneQueue.'"))
            .containing(.staticText, identifier: "Layout Track 3").firstMatch
        queuedTrack.tap()
        XCTAssertEqual(queuedTrack.value as? String, language == "ja" ? "再生中" : "Playing")
        app.buttons["phonePlayPause"].tap()
        XCTAssertEqual(queuedTrack.value as? String, language == "ja" ? "一時停止中" : "Paused")
        app.buttons["phoneStop"].tap()
        XCTAssertEqual(queuedTrack.value as? String, language == "ja" ? "停止中" : "Stopped")
        app.buttons["phoneDeckClose"].tap()
        XCTAssertTrue(dock.waitForExistence(timeout: 5))
        verifyTrackAccessibility(in: app, language: language)
    }

    @MainActor private func verifyTrackAccessibility(in app: XCUIApplication, language: String) {
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'"))
            .containing(.staticText, identifier: "Layout Track 3").firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        XCTAssertTrue(track.label.contains("Layout Track 3"), "VoiceOver needs the complete track title")
        XCTAssertTrue(track.label.contains("Layout Artist"), "VoiceOver needs the artist")
        XCTAssertEqual(track.value as? String, language == "ja" ? "停止中" : "Stopped")
        let play = app.buttons["phoneDockPlayPause"]
        play.tap()
        XCTAssertEqual(track.value as? String, language == "ja" ? "再生中" : "Playing")
        play.tap()
        XCTAssertEqual(track.value as? String, language == "ja" ? "一時停止中" : "Paused")
    }

    @MainActor private func assertTouchTarget(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.exists)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44)
        XCTAssertTrue(app.frame.contains(element.frame), "Control extends beyond the screen: \(element.identifier)")
    }

    @MainActor private func verifyDock(in app: XCUIApplication, name: String) {
        let dock = app.buttons["phoneLEDDock"]
        let play = app.buttons["phoneDockPlayPause"]
        let next = app.buttons["phoneDockNext"]
        attachScreenshot(in: app, name: name)
        for button in [dock, play, next] { assertTouchTarget(button, in: app) }
        XCTAssertGreaterThanOrEqual(play.frame.minX - dock.frame.maxX, 8, "Track and play controls need separation")
        XCTAssertGreaterThanOrEqual(next.frame.minX - play.frame.maxX, 8, "Playback controls need separation")
        XCTAssertEqual(play.frame.midY, next.frame.midY, accuracy: 1)
    }

    @MainActor private func attachScreenshot(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif

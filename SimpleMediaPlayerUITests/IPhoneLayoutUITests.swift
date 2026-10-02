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

    @MainActor private func launch(language: String, appearance: String, style: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            "-appearanceMode", appearance, "-ledDisplayStyle", style,
            "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        return app
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
        assertTouchTarget(app.buttons["phoneDockPlayPause"], in: app)
        assertTouchTarget(app.buttons["phoneDockNext"], in: app)
        dock.tap()
        XCTAssertTrue(app.buttons["phoneDeckClose"].waitForExistence(timeout: 5))
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
        app.buttons["phonePage.Info"].tap()
        XCTAssertTrue(app.buttons[language == "ja" ? "情報を編集…" : "Edit Information…"].waitForExistence(timeout: 5))
        app.buttons["phonePage.Up Next"].tap()
        XCTAssertTrue(app.staticTexts["Layout Track 3"].waitForExistence(timeout: 5))
        let queuedTrack = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneQueue.'"))
            .containing(.staticText, identifier: "Layout Track 3").firstMatch
        queuedTrack.tap()
        XCTAssertEqual(queuedTrack.value as? String, language == "ja" ? "再生中" : "Playing")
        app.buttons["phoneDeckClose"].tap()
        XCTAssertTrue(dock.waitForExistence(timeout: 5))
    }

    @MainActor private func assertTouchTarget(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.exists)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44)
        XCTAssertTrue(app.frame.contains(element.frame), "Control extends beyond the screen: \(element.identifier)")
    }
}
#endif

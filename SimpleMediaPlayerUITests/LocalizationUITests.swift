import XCTest

final class LocalizationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishMainScreenAndSettings() {
        assertLocalizedScreens(
            language: "en", locale: "en_US", name: "English",
            buttonLabels: ["pitchButton": "Key", "speedButton": "Speed", "settingsButton": "Settings"],
            close: "Close"
        )
    }

    @MainActor
    func testJapaneseMainScreenAndSettings() {
        assertLocalizedScreens(
            language: "ja", locale: "ja_JP", name: "Japanese",
            buttonLabels: ["pitchButton": "キー", "speedButton": "速度", "settingsButton": "設定"],
            close: "閉じる"
        )
    }

    @MainActor
    private func assertLocalizedScreens(
        language: String, locale: String, name: String,
        buttonLabels: [String: String], close: String
    ) {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "-ApplePersistenceIgnoreState", "YES",
            "-bottomPanelLayout", "classic"
        ]
        app.launch()
        app.activate()
        let mainWindowAnchor = app.buttons["addPlaylistButton"]
        if !mainWindowAnchor.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(mainWindowAnchor.waitForExistence(timeout: 5), "The main player window did not open")
        attachScreenshot(of: app, named: "\(name) Main Screen")

        for (identifier, label) in buttonLabels {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "Missing \(identifier)")
            XCTAssertEqual(button.label, label, "Unexpected \(language) label for \(identifier)")
        }

        app.buttons["settingsButton"].click()
        let closeButton = app.buttons["settingsCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        attachScreenshot(of: app, named: "\(name) Settings")
        XCTAssertEqual(closeButton.label, close)
        closeButton.click()
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

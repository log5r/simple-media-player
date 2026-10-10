#if os(iOS)
import UIKit
import XCTest

/// The simulator has no Music library and cannot host the picker, so these tests verify the entry
/// points and the app's own alert. Revoke the permission first to exercise the denied path:
/// `xcrun simctl privacy <device> revoke media-library com.log5.SimpleMediaPlayer`. With the
/// permission undecided, the system prompt is declined through an interruption monitor.
final class MusicLibraryEntryPointUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testPhoneMenuOffersMusicEntryPointsAndExplainsAccess() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This test verifies the phone layout.")
        let app = launch(compact: true)
        XCTAssertTrue(app.buttons["phoneLibraryMore"].waitForExistence(timeout: 10))
        app.buttons["phoneLibraryMore"].tap()
        XCTAssertTrue(app.buttons["playFromMusicButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["importFromMusicButton"].exists)
        XCTAssertTrue(app.buttons["importMediaButton"].exists)

        app.buttons["playFromMusicButton"].tap()
        expectMusicLibraryAlert(in: app)
    }

    @MainActor func testTabletToolbarOffersMusicEntryPointsAndExplainsAccess() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "This test verifies the tablet layout.")
        let app = launch(compact: false)
        XCTAssertTrue(app.buttons["musicLibraryMenu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["importMediaButton"].exists)
        app.buttons["musicLibraryMenu"].tap()
        XCTAssertTrue(app.buttons["playFromMusicButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["importFromMusicButton"].exists)

        app.buttons["importFromMusicButton"].tap()
        expectMusicLibraryAlert(in: app)
    }

    /// Either the denied explanation with Open Settings, or the Simulator notice when access was granted.
    @MainActor private func expectMusicLibraryAlert(in app: XCUIApplication) {
        let monitor = addUIInterruptionMonitor(withDescription: "Music permission prompt") { prompt in
            // The prompt follows the device language; its leading button declines.
            let decline = prompt.buttons.element(boundBy: 0)
            guard decline.exists else { return false }
            decline.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let alert = app.alerts["Music Library"]
        if alert.waitForExistence(timeout: 3) == false {
            // Interruption monitors run on interaction, not on existence checks.
            app.tap()
        }
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let expectedWord = alert.buttons["Open Settings"].exists ? "Settings" : "Simulator"
        let message = alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", expectedWord))
        XCTAssertTrue(message.firstMatch.exists)
        alert.buttons["OK"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 1))
    }

    @MainActor private func launch(compact: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-volumeNormalizationEnabled", "NO"
        ]
        if compact { app.launchArguments.append("--ui-testing-compact-layout") }
        app.launch()
        return app
    }
}
#endif

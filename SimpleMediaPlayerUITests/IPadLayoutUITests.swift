#if os(iOS)
import UIKit
import XCTest

final class IPadLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "This suite verifies the tablet layout.")
    }

    @MainActor func testMainScreenAndSettingsKeepTabletLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-phone-layout", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["addPlaylistButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["lyricsButton"].exists)
        XCTAssertTrue(app.buttons["pitchButton"].exists)
        XCTAssertFalse(app.buttons["phoneLEDDock"].exists)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["settingsCloseButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit Columns"].exists)
        app.buttons["settingsCloseButton"].tap()
    }
}
#endif

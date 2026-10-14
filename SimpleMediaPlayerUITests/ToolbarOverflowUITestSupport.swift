#if os(iOS)
import XCTest

extension XCUIApplication {
    /// The system button that opens a `ToolbarOverflowMenu`.
    /// It does not keep the app's accessibility identifiers and its label is localized. iOS 27.0 and 27.1 name it
    /// `OverflowBarButtonItem` in the navigation bar and `BottomOverflowBarButtonItem` when the vertical
    /// toolbar (iPhone Duo's outer screen) hosts it, so match the shared suffix outside any one bar.
    /// Only the front screen's button is exposed; check the navigation bar when a case must tell screens apart.
    @MainActor func toolbarOverflowButton() -> XCUIElement {
        buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "OverflowBarButtonItem")).firstMatch
    }

    /// Opens the overflow menu and returns one of its items.
    /// The items drop their accessibility identifiers on iOS 27.0 and 27.1, so match the localized label.
    @MainActor func openToolbarOverflowMenu(item label: String) -> XCUIElement {
        let button = toolbarOverflowButton()
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Toolbar overflow button")
        button.tap()
        let item = buttons[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), label)
        return item
    }
}
#endif

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
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-reset-led-settings",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["addPlaylistButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["lyricsButton"].exists)
        XCTAssertTrue(app.buttons["pitchButton"].exists)
        XCTAssertFalse(app.buttons["phoneLEDDock"].exists)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["settingsCloseButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit Columns"].exists)
        let panelLayout = app.segmentedControls.containing(.button, identifier: "Classic").firstMatch
        scrollTo(panelLayout, in: app)
        XCTAssertTrue(panelLayout.isHittable, "Standard tablet settings must retain the segmented panel picker")
        XCTAssertTrue(panelLayout.buttons["LED Half"].exists)
        app.buttons["settingsCloseButton"].tap()
    }

    @MainActor func testLEDGlassPickerAtLargestAccessibilitySize() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-reset-led-settings",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["settingsCloseButton"].waitForExistence(timeout: 5))
        let font = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        let values = ["off", "cylindrical", "crtBulge", "bevel"]
        let labels = ["Off", "Cylindrical", "CRT Bulge", "Bevel"]
        for index in values.indices {
            let button = app.buttons["ledPicker.ledGlassStyle.\(values[index])"]
            scrollTo(button, in: app)
            verifyLabel(button, title: labels[index], font: font, in: app)
            XCTAssertEqual(button.isSelected, index == 0, "Off must be the only initial glass selection")
        }
        let bevel = app.buttons["ledPicker.ledGlassStyle.bevel"]
        bevel.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: bevel
        )
        wait(for: [selected], timeout: 5)
        XCTAssertFalse(app.buttons["ledPicker.ledGlassStyle.off"].isSelected)
    }

    @MainActor private func verifyLabel(
        _ button: XCUIElement, title: String, font: UIFont, in app: XCUIApplication
    ) {
        XCTAssertTrue(button.isHittable, "Glass option must be reachable: \(title)")
        XCTAssertTrue(app.frame.contains(button.frame), "Glass option extends beyond the screen: \(title)")
        XCTAssertEqual(button.label, title, "VoiceOver must receive the complete option title")
        let label = button.staticTexts[title]
        let textFrame = label.exists ? label.frame : CGRect(
            x: button.frame.minX + 12, y: button.frame.minY + 8,
            width: button.frame.width - font.lineHeight - 34, height: button.frame.height - 16
        )
        XCTAssertGreaterThan(textFrame.width, 0, "No space remains for the glass title: \(title)")
        let requiredSize = (title as NSString).boundingRect(
            with: CGSize(width: textFrame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
        ).size
        XCTAssertGreaterThanOrEqual(textFrame.width, requiredSize.width - 2, "Glass title is compressed: \(title)")
        XCTAssertGreaterThanOrEqual(
            textFrame.height, max(font.lineHeight, requiredSize.height) - 2, "Glass title is clipped: \(title)"
        )
        XCTAssertTrue(button.frame.contains(textFrame), "Glass title extends beyond its button: \(title)")
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        let visibleFrame = (form.exists ? form.frame : app.frame).insetBy(dx: 8, dy: 40)
        for _ in 0..<30 {
            if element.exists, element.isHittable,
               element.frame.minY >= visibleFrame.minY, element.frame.maxY <= visibleFrame.maxY { return }
            let scrollsUp = element.exists && element.frame.height > 0 && element.frame.minY < visibleFrame.minY
            let container = form.exists ? form : app
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsUp ? 0.4 : 0.8))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsUp ? 0.8 : 0.4))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not bring tablet setting fully into view: \(element)")
    }
}
#endif

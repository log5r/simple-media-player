#if os(iOS)
import UIKit
import XCTest

final class LEDSettingsLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone layout.")
    }

    @MainActor func testEnglishPresetsAtLargestAccessibilitySize() {
        verifyPresets(language: "en", labels: ["Green", "White", "Blue", "Orange"], colorLabel: "Foreground Color")
    }

    @MainActor func testJapanesePresetsAtLargestAccessibilitySize() {
        verifyPresets(language: "ja", labels: ["緑", "白", "青", "オレンジ"], colorLabel: "表示色")
    }

    @MainActor func testEnglishPresetsAtDefaultSize() {
        verifyPresets(
            language: "en", labels: ["Green", "White", "Blue", "Orange"],
            colorLabel: "Foreground Color", usesAccessibilitySize: false
        )
    }

    @MainActor private func verifyPresets(
        language: String, labels: [String], colorLabel: String, usesAccessibilitySize: Bool = true
    ) {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout",
            "-UIPreferredContentSizeCategoryName",
            usesAccessibilitySize ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            "-ledDisplayStyle", "dark", "-ledColorHex", "#B8E887", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let more = app.buttons["phoneLibraryMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["settingsCloseButton"].waitForExistence(timeout: 5))

        let font = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: usesAccessibilitySize ? .accessibilityExtraExtraExtraLarge : .large
            )
        )
        for name in labels {
            let button = app.buttons[name]
            scrollTo(button, in: app)
            attachScreenshot(in: app, name: "LED preset \(language) \(name)")
            XCTAssertTrue(button.isHittable, "Preset must remain reachable: \(name)")
            XCTAssertTrue(app.frame.contains(button.frame), "Preset extends beyond the screen: \(name)")
            let label = button.staticTexts[name]
            let expectedSize = (name as NSString).size(withAttributes: [.font: font])
            let textFrame = label.exists ? label.frame : button.frame
            XCTAssertGreaterThanOrEqual(textFrame.width, expectedSize.width - 2, "Preset text is compressed: \(name)")
            XCTAssertGreaterThanOrEqual(textFrame.height, font.lineHeight - 2, "Preset text is clipped: \(name)")
            XCTAssertTrue(button.frame.contains(textFrame), "Preset text extends beyond its button: \(name)")
        }

        let orange = app.buttons[labels[3]]
        orange.tap()
        XCTAssertTrue(app.frame.contains(orange.frame), "Selected preset extends beyond the screen")
        let foregroundColor = app.textFields[colorLabel]
        scrollTo(foregroundColor, in: app)
        XCTAssertEqual(foregroundColor.value as? String, "#FF9F2E")
        attachScreenshot(in: app, name: "LED selected orange \(language)")
        let hexFont = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        let hexWidth = ("#FF9F2E" as NSString).size(withAttributes: [.font: hexFont]).width
        XCTAssertGreaterThan(foregroundColor.frame.width, hexWidth, "The complete hex value must fit")
        let apply = app.buttons[colorLabel]
        scrollTo(apply, in: app)
        XCTAssertTrue(app.frame.contains(apply.frame), "Apply extends beyond the screen")
        apply.tap()
        XCTAssertEqual(foregroundColor.value as? String, "#FF9F2E")
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let visibleFrame = app.frame.insetBy(dx: 8, dy: 80)
        for _ in 0..<24 {
            if element.exists, element.isHittable,
               element.frame.minY >= visibleFrame.minY, element.frame.maxY <= visibleFrame.maxY { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not bring control fully into view: \(element)")
    }

    @MainActor private func attachScreenshot(in app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif

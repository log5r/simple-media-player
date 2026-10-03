#if os(iOS)
import CoreText
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

    @MainActor func testEnglishPickersAtLargestAccessibilitySize() {
        verifyPickers(language: "en")
    }

    @MainActor func testJapanesePickersAtLargestAccessibilitySize() {
        verifyPickers(language: "ja")
    }

    @MainActor func testEnglishPickersAtDefaultSize() {
        verifyPickers(language: "en", usesAccessibilitySize: false)
    }

    @MainActor private func openSettings(
        language: String, usesAccessibilitySize: Bool
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-reset-led-settings",
            "-UIPreferredContentSizeCategoryName",
            usesAccessibilitySize ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let more = app.buttons["phoneLibraryMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["settingsCloseButton"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func bodyFont(usesAccessibilitySize: Bool) -> UIFont {
        UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: usesAccessibilitySize ? .accessibilityExtraExtraExtraLarge : .large
            )
        )
    }

    @MainActor private func verifyPresets(
        language: String, labels: [String], colorLabel: String, usesAccessibilitySize: Bool = true
    ) {
        let app = openSettings(language: language, usesAccessibilitySize: usesAccessibilitySize)
        let font = bodyFont(usesAccessibilitySize: usesAccessibilitySize)
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

    private struct PickerGroup {
        let key: String
        let values: [String]
        let labels: [String]
        let initial: String
    }

    private func pickerGroups(language: String) -> [PickerGroup] {
        let japanese = language == "ja"
        return [
            PickerGroup(
                key: "ledDisplayStyle", values: ["dark", "backlit"],
                labels: japanese ? ["ダーク", "バックライト"] : ["Dark", "Backlit"], initial: "dark"
            ),
            PickerGroup(
                key: "timeDisplayStyle", values: ["sevenSegment", "dotted"],
                labels: japanese ? ["7セグメント", "ドット"] : ["7-segment", "Dot"], initial: "sevenSegment"
            ),
            PickerGroup(
                key: "mediaInfoDisplayStyle", values: ["default", "dotted"],
                labels: japanese ? ["デフォルト", "ドット"] : ["Default", "Dot"], initial: "default"
            ),
            PickerGroup(
                key: "ledGlassStyle", values: ["off", "cylindrical", "crtBulge", "bevel"],
                labels: japanese ? ["オフ", "円筒ガラス", "CRTバルジ", "ベベルガラス"]
                    : ["Off", "Cylindrical", "CRT Bulge", "Bevel"], initial: "off"
            ),
            PickerGroup(
                key: "visualizerResponseMode", values: ["slow", "normal", "fast"],
                labels: japanese ? ["低速", "通常", "高速"] : ["Slow", "Normal", "Fast"], initial: "normal"
            )
        ]
    }

    @MainActor private func verifyPickers(language: String, usesAccessibilitySize: Bool = true) {
        let app = openSettings(language: language, usesAccessibilitySize: usesAccessibilitySize)
        let font = bodyFont(usesAccessibilitySize: usesAccessibilitySize)
        for group in pickerGroups(language: language) {
            for index in group.values.indices {
                let button = pickerOption(group, index: index, in: app)
                scrollTo(button, in: app)
                verifyPickerLabel(button, name: group.labels[index], font: font, language: language, in: app)
            }
            attachScreenshot(in: app, name: "LED picker \(language) \(group.key)")
            let last = pickerOption(group, index: group.values.count - 1, in: app)
            last.tap()
            waitForSelection(last, selected: true)
            let initialIndex = group.values.firstIndex(of: group.initial) ?? 0
            let initial = pickerOption(group, index: initialIndex, in: app)
            XCTAssertFalse(initial.isSelected, "Previous picker option must lose the selected trait")
            scrollTo(initial, in: app, preferUp: true)
            initial.tap()
            waitForSelection(initial, selected: true)
            XCTAssertFalse(last.isSelected, "The previous choice must lose the selected trait")
        }
    }

    @MainActor private func pickerOption(
        _ group: PickerGroup, index: Int, in app: XCUIApplication
    ) -> XCUIElement {
        let identified = app.buttons["ledPicker.\(group.key).\(group.values[index])"]
        if identified.exists { return identified }
        // Keep the original segmented implementation measurable for the regression check.
        let anchorIndex = group.key == "ledDisplayStyle" || group.key == "ledGlassStyle" ? 1 : 0
        let segmented = app.segmentedControls.containing(.button, identifier: group.labels[anchorIndex]).firstMatch
        if segmented.exists { return segmented.buttons[group.labels[index]] }
        return identified
    }

    @MainActor private func verifyPickerLabel(
        _ button: XCUIElement, name: String, font: UIFont, language: String, in app: XCUIApplication
    ) {
        XCTAssertTrue(button.isHittable, "Picker option must remain reachable: \(name)")
        XCTAssertTrue(app.frame.contains(button.frame), "Picker option extends beyond the screen: \(name)")
        XCTAssertEqual(button.label, name, "VoiceOver must receive the complete localized option")
        let label = button.staticTexts[name]
        let textFrame = label.exists ? label.frame : CGRect(
            x: button.frame.minX + 12, y: button.frame.minY + 8,
            width: button.frame.width - font.lineHeight - 34, height: button.frame.height - 16
        )
        XCTAssertGreaterThan(textFrame.width, 0, "No space remains for the picker label: \(name)")
        let requiredSize = (name as NSString).boundingRect(
            with: CGSize(width: textFrame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
        ).size
        let requiredHeight = glyphHeight(name, font: font, width: textFrame.width, language: language)
        XCTAssertGreaterThanOrEqual(textFrame.width, requiredSize.width - 2, "Picker text is compressed: \(name)")
        XCTAssertGreaterThanOrEqual(
            textFrame.height, requiredHeight - 2, "Picker text is clipped: \(name)"
        )
        XCTAssertTrue(button.frame.contains(textFrame), "Picker text extends beyond its button: \(name)")
    }

    @MainActor private func glyphHeight(_ text: String, font: UIFont, width: CGFloat, language: String) -> CGFloat {
        // Accessibility frames may fit Japanese glyphs tightly instead of including SF's full line height.
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTLanguageAttributeName as String): language
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(
            x: 0, y: 0, width: width, height: font.lineHeight * CGFloat(attributed.length + 1)
        ), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        XCTAssertEqual(CTFrameGetVisibleStringRange(frame).length, attributed.length)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        XCTAssertFalse(lines.isEmpty, "Body-font measurement must include the complete label")
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let bounds = zip(lines, origins).reduce(CGRect.null) { result, line in
            result.union(CTLineGetBoundsWithOptions(line.0, .useGlyphPathBounds).offsetBy(dx: line.1.x, dy: line.1.y))
        }
        return bounds.height
    }

    @MainActor private func waitForSelection(_ button: XCUIElement, selected: Bool) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)), object: button
        )
        wait(for: [changed], timeout: 5)
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, preferUp: Bool = false) {
        let visibleFrame = app.frame.insetBy(dx: 8, dy: 80)
        for _ in 0..<24 {
            let frame = element.exists ? element.frame : .zero
            if frame.height > 0, element.isHittable,
               frame.minY >= visibleFrame.minY, frame.maxY <= visibleFrame.maxY { return }
            let scrollsUp = frame.height > 0 ? frame.minY < visibleFrame.minY : preferUp
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsUp ? 0.5 : 0.75))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsUp ? 0.75 : 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
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

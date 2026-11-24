#if os(iOS)
import UIKit
import XCTest

extension DuoPlayerDesignUITests {
    @MainActor func testOpenPortraitShowsFullAccessibilitySeekTimes() throws {
        try assertPortraitAccessibilitySeekTimes(folded: false)
    }

    @MainActor func testBookPortraitShowsFullAccessibilitySeekTimes() throws {
        try assertPortraitAccessibilitySeekTimes(folded: true)
    }

    @MainActor private func assertPortraitAccessibilitySeekTimes(folded: Bool) throws {
        let category = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        let app = try launch(portrait: true, contentSizeCategory: category)
        let geometry = try metrics(duoDiagnostic("duoLayoutMetrics", in: app))
        try XCTSkipUnless(geometry["hasActiveDivision"] as? Bool == folded, "Select this case's posture in Device Hub.")
        let seek = try regionFrame("duoPortraitSeek", in: app)
        assertSeekTimesFit(in: app, contentSizeCategory: category, within: seek)
    }

    /// Open the deck on the outside display first. Launching directly in Open landscape shows the library.
    @MainActor func testOpenLandscapeDeckShowsFullAccessibilitySeekTimes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUO_INTERACTIVE_POSE_TESTS"] == "1",
                          "Start Closed and change to Open landscape in Device Hub when prompted.")
        let category = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        let app = launchPlayer(contentSizeCategory: category)
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let initial = try metrics(layout)
        let insets = initial["safeArea"] as? [String: Double] ?? [:]
        try XCTSkipUnless(
            initial["layout"] as? String == "compact" && initial["portrait"] as? Bool == true
                && insets["leading", default: 0] + insets["trailing", default: 0] > 0,
            "Start on the Duo's Closed portrait display."
        )
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        dock.tap()
        let close = app.buttons["phoneDeckClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))

        print("DuoPostureStep Open landscape")
        fflush(nil)
        let player = app.otherElements["duoLandscapePlayer"]
        XCTAssertTrue(player.waitForExistence(timeout: 120))
        let controls = player.otherElements["expandedControlsRegion"]
        assertSeekTimesFit(in: controls, contentSizeCategory: category, within: controls.frame.intersection(app.frame))

        close.tap()
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        let geometry = try metrics(layout)
        XCTAssertEqual(geometry["hasActiveDivision"] as? Bool, false, "Open the Duo fully.")
        XCTAssertEqual(geometry["portrait"] as? Bool, false)
    }
}
#endif

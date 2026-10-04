#if os(iOS)
import Darwin
import UIKit
import XCTest

/// Run with DUO_INTERACTIVE_POSE_TESTS=1 in the test runner's environment.
/// The operator selects Closed, Book, then Open in Device Hub when each activity appears.
final class DuoFoldTransitionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DUO_INTERACTIVE_POSE_TESTS"] == "1",
            "This test requires an operator changing real Duo postures in Device Hub."
        )
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the Duo phone layout.")
    }

    @MainActor func testOpenClosedBookPlaybackContinuity() throws {
        let app = launchApp(extraArguments: ["--ui-testing-audible-layout"])
        let geometry = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(geometry.waitForExistence(timeout: 10))
        XCTAssertTrue((geometry.value as? String)?.contains("\"layout\":\"expanded\"") == true)
        let track = fixtureTrack(in: app)
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        waitForValue("\"playing\":true", in: playback, timeout: 10)
        var previous = try metrics(playback)

        let transitions = [
            ("Closed", "\"layout\":\"compact\""),
            ("Book", "\"hasActiveDivision\":true"),
            ("Open", "\"hasActiveDivision\":false")
        ]
        for (posture, expected) in transitions {
            try XCTContext.runActivity(named: "Select \(posture) posture in Device Hub") { _ in
                print("DuoPostureStep \(posture)")
                fflush(nil)
                waitForValue(expected, in: geometry, timeout: 45)
                let current = try metrics(playback)
                XCTAssertEqual(current["itemID"] as? String, previous["itemID"] as? String)
                XCTAssertEqual(current["queueIDs"] as? [String], previous["queueIDs"] as? [String])
                XCTAssertEqual(current["playing"] as? Bool, true)
                XCTAssertGreaterThan(try number("time", in: current), try number("time", in: previous))
                XCTAssertGreaterThan(try number("rmsL", in: current), 0)
                XCTAssertGreaterThan(try number("rmsR", in: current), 0)
                for key in ["volume", "pitch", "rate", "generation"] {
                    XCTAssertEqual(try number(key, in: current), try number(key, in: previous))
                }
                previous = current
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Duo real \(posture) posture playback"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let geometryAttachment = XCTAttachment(string: geometry.value as? String ?? "missing")
                geometryAttachment.name = "Duo real \(posture) geometry"
                geometryAttachment.lifetime = .keepAlways
                add(geometryAttachment)
            }
        }
        XCTAssertTrue(app.buttons["pauseButton"].waitForExistence(timeout: 5))
        app.buttons["pauseButton"].tap()
        waitForValue("\"paused\":true", in: playback, timeout: 5)
    }

    @MainActor func testLyricsDraftSurvivesRealFolding() throws {
        let app = launchApp()
        let track = fixtureTrack(in: app)
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()
        let edit = app.buttons["Edit Lyrics…"].firstMatch
        if !edit.exists { toolbarButton("lyricsButton", in: app).tap() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let editor = app.textViews["Lyrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\nDuo real folding draft")
        let editorMetrics = duoDiagnostic("duoEditorMetrics", in: app)
        XCTAssertTrue(editorMetrics.waitForExistence(timeout: 5))
        let original = try metrics(editorMetrics)
        let layout = duoDiagnostic("duoEditorLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        let transitions = [
            ("Closed", "\"horizontalSizeClass\":\"compact\""),
            ("Book", "\"hasActiveDivision\":true"),
            ("Open", "\"hasActiveDivision\":false")
        ]
        for (posture, expected) in transitions {
            try XCTContext.runActivity(named: "Select \(posture) posture with lyrics draft in Device Hub") { _ in
                print("DuoPostureStep \(posture) lyrics")
                fflush(nil)
                waitForValue(expected, in: layout, timeout: 45)
                XCTAssertTrue(editor.exists)
                XCTAssertTrue((editor.value as? String)?.contains("Duo real folding draft") == true)
                let current = try metrics(editorMetrics)
                for key in ["itemID", "sessionID"] {
                    XCTAssertEqual(current[key] as? String, original[key] as? String)
                }
                XCTAssertEqual(
                    current["draftHashes"] as? [String: String], original["draftHashes"] as? [String: String]
                )
                XCTAssertEqual(current["draftLengths"] as? [String: Int], original["draftLengths"] as? [String: Int])
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Duo real \(posture) posture lyrics draft"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let diagnostics = XCTAttachment(string: editorMetrics.value as? String ?? "missing")
                diagnostics.name = "Duo real \(posture) editor session"
                diagnostics.lifetime = .keepAlways
                add(diagnostics)
            }
        }
        app.buttons["Cancel"].tap()
    }

    @MainActor private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        if ProcessInfo.processInfo.environment["DUO_INTERACTIVE_ORIENTATION_TESTS"] != "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-duo-long-playback",
            "-mediaListColumnOrder", "index,title,artist,album,duration",
            "-mediaListVisibleColumns", "index,title,artist,album,duration",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ] + extraArguments
        app.launch()
        rotateDuo(to: .landscapeLeft, in: app)
        return app
    }

    @MainActor private func fixtureTrack(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'libraryTrack.' AND label CONTAINS %@", "Layout Track 1")
        ).firstMatch
    }

    @MainActor private func toolbarButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier]
        if !button.exists {
            let overflow = app.buttons["BottomOverflowBarButtonItem"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 5))
            overflow.tap()
        }
        if button.waitForExistence(timeout: 2) { return button }
        let nativeMenuItem = app.buttons[identifier == "lyricsButton" ? "Details" : identifier].firstMatch
        XCTAssertTrue(nativeMenuItem.waitForExistence(timeout: 5), identifier)
        return nativeMenuItem
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func number(_ key: String, in values: [String: Any]) throws -> Double {
        try XCTUnwrap(values[key] as? Double)
    }

    @MainActor private func waitForValue(_ value: String, in element: XCUIElement, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", value), object: element
        )
        wait(for: [expectation], timeout: timeout)
    }
}
#endif

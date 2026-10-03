#if os(iOS)
import UIKit
import XCTest

/// Select the Duo's Open posture in Device Hub before running this suite.
/// Enable DUO_INTERACTIVE_ORIENTATION_TESTS=1 if XCTest cannot rotate the actual Duo display.
final class DuoLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the Duo phone layout.")
    }

    @MainActor func testExpandedPlaybackControlsAndRotationPreservePlayback() throws {
        let app = try launchExpanded()
        let track = fixtureTrack(in: app)
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        waitForValue("\"playing\":true", in: playback)
        let original = try metrics(playback)
        for identifier in ["playButton", "pauseButton", "stopButton", "nextTrackButton", "volumeUpButton"] {
            assertTouchTarget(app.buttons[identifier], in: app)
        }
        attachDiagnostics(in: app, name: "Duo open landscape playing")

        rotateDuo(to: .portrait, in: app)
        let current = try metrics(playback)
        XCTAssertEqual(current["itemID"] as? String, original["itemID"] as? String)
        XCTAssertEqual(current["queueIDs"] as? [String], original["queueIDs"] as? [String])
        XCTAssertEqual(try number("generation", in: current), try number("generation", in: original))
        XCTAssertEqual(current["playing"] as? Bool, true)
        XCTAssertGreaterThan(try number("time", in: current), try number("time", in: original))
        attachDiagnostics(in: app, name: "Duo open portrait playing")

        rotateDuo(to: .landscapeLeft, in: app)
        let pause = app.buttons["pauseButton"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        waitForValue("\"paused\":true", in: playback)
        let paused = try metrics(playback)
        rotateDuo(to: .portrait, in: app)
        XCTAssertEqual(try metrics(playback)["itemID"] as? String, paused["itemID"] as? String)
        XCTAssertEqual(try metrics(playback)["paused"] as? Bool, true)
        XCTAssertEqual(try number("generation", in: metrics(playback)), try number("generation", in: paused))
        rotateDuo(to: .landscapeLeft, in: app)
    }

    @MainActor func testExpandedSettingsExposePanelAndColumnPreferences() throws {
        let app = try launchExpanded()
        XCTAssertFalse(app.buttons["phoneLEDDock"].exists)
        toolbarButton("settingsButton", in: app).tap()
        XCTAssertTrue(app.buttons["settingsCloseButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit Columns"].exists)
        XCTAssertTrue(app.segmentedControls.containing(.button, identifier: "Classic").firstMatch.exists)
        attachDiagnostics(in: app, name: "Duo expanded settings")
        app.buttons["settingsCloseButton"].tap()
    }

    @MainActor func testLyricsDraftSurvivesRotation() throws {
        let app = try launchExpanded()
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
        editor.typeText("\nDuo rotation draft")
        rotateDuo(
            to: .portrait, in: app, layoutIdentifier: "duoEditorLayoutMetrics", portraitKey: "scenePortrait"
        )
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Duo rotation draft") == true)
        attachDiagnostics(in: app, name: "Duo lyrics draft portrait keyboard")
        rotateDuo(
            to: .landscapeLeft, in: app, layoutIdentifier: "duoEditorLayoutMetrics", portraitKey: "scenePortrait"
        )
        XCTAssertTrue((editor.value as? String)?.contains("Duo rotation draft") == true)
        app.buttons["Cancel"].tap()
    }

    @MainActor func testExportNameSheetSurvivesRotationWithKeyboard() throws {
        let app = try launchExpanded()
        let export = toolbarButton("exportToFinderButton", in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(export.isEnabled)
        export.tap()
        let fillNames = app.buttons["Fill All Names with Timestamps"]
        XCTAssertTrue(fillNames.waitForExistence(timeout: 10))
        fillNames.tap()
        app.buttons["Fill with Timestamps"].tap()
        let field = app.textFields["File name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" Duo")
        let name = field.value as? String
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        rotateDuo(
            to: .portrait, in: app, layoutIdentifier: "duoEditorLayoutMetrics", portraitKey: "scenePortrait"
        )
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, name)
        let save = app.buttons["Export"]
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(app.frame.contains(cancel.frame))
        attachDiagnostics(in: app, name: "Duo export names portrait keyboard")
        rotateDuo(
            to: .landscapeLeft, in: app, layoutIdentifier: "duoEditorLayoutMetrics", portraitKey: "scenePortrait"
        )
        XCTAssertEqual(field.value as? String, name)
        cancel.tap()
    }

    @MainActor private func launchExpanded() throws -> XCUIApplication {
        if ProcessInfo.processInfo.environment["DUO_INTERACTIVE_ORIENTATION_TESTS"] != "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-reset-led-settings",
            "--ui-testing-duo-long-playback",
            "-mediaListColumnOrder", "index,title,artist,album,duration",
            "-mediaListVisibleColumns", "index,title,artist,album,duration",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let diagnostics = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        let geometry = try metrics(diagnostics)
        let division = geometry["division"] as? [[String: Any]] ?? []
        try XCTSkipIf(division.isEmpty, "Run this suite on iPhone Duo in Device Hub's Open posture.")
        XCTAssertEqual(geometry["layout"] as? String, "expanded", "Select Open posture before running this suite")
        XCTAssertEqual(geometry["horizontalSizeClass"] as? String, "regular")
        rotateDuo(to: .landscapeLeft, in: app)
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 5))
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
        let labels = [
            "settingsButton": "Settings", "lyricsButton": "Details", "exportToFinderButton": "Export"
        ]
        let nativeMenuItem = app.buttons[labels[identifier] ?? identifier].firstMatch
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

    @MainActor private func waitForValue(_ value: String, in element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", value), object: element
        )
        wait(for: [expectation], timeout: 10)
    }

    @MainActor private func assertTouchTarget(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.exists, element.identifier)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, element.identifier)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, element.identifier)
        XCTAssertTrue(app.frame.contains(element.frame), element.identifier)
    }

    @MainActor private func attachDiagnostics(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let geometry = duoDiagnostic("duoLayoutMetrics", in: app)
        let value = geometry.exists ? geometry.value as? String : "Root geometry is hidden by the presented sheet."
        let diagnostics = XCTAttachment(string: value ?? "missing")
        diagnostics.name = "\(name) geometry"
        diagnostics.lifetime = .keepAlways
        add(diagnostics)
    }
}
#endif

#if os(iOS)
import Darwin
import UIKit
import XCTest

/// Enable DUO_INTERACTIVE_POSE_TESTS=1 and follow DuoPostureStep in Device Hub.
/// DUO_INTERACTIVE_KEYBOARD_TESTS=1 also leaves Command+Option+E to the operator.
final class DuoDeckEqualizerTransitionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUO_INTERACTIVE_POSE_TESTS"] == "1",
                          "This suite needs real Closed to Open/Book changes in Device Hub.")
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the Duo phone layout.")
    }

    @MainActor func testDeckEqualizerSurvivesOpeningToLandscape() throws {
        try verifyTransition(to: "Open landscape", portrait: false, folded: false)
    }

    @MainActor func testDeckEqualizerSurvivesOpeningToPortrait() throws {
        try verifyTransition(to: "Open portrait", portrait: true, folded: false)
    }

    @MainActor func testDeckEqualizerSurvivesOpeningToBook() throws {
        try verifyTransition(to: "Book portrait", portrait: true, folded: true)
    }

    @MainActor private func verifyTransition(to posture: String, portrait: Bool, folded: Bool) throws {
        let app = launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        checkpoint("Closed portrait")
        waitForMetrics(layout, timeout: 120, consecutiveMatches: 3) { values in
            let insets = values["safeArea"] as? [String: Double] ?? [:]
            return values["layout"] as? String == "compact" && values["portrait"] as? Bool == true
                && insets["leading", default: 0] + insets["trailing", default: 0] > 0
        }
        openDeck(in: app)
        try assertEqualizer(isPresented: false, in: app)
        toggleEqualizer(in: app, expectingPresented: true)
        try assertEqualizer(isPresented: true, in: app)

        // Keep the same sheet open across the size-class and posture change.
        checkpoint(posture + " with deck equalizer open")
        let diagnostics = duoDiagnostic("duoEqualizerMetrics", in: app)
        waitForMetrics(diagnostics, timeout: 120, consecutiveMatches: 3) { values in
            values["layout"] as? String == "expanded" && values["portrait"] as? Bool == portrait
                && values["hasActiveDivision"] as? Bool == folded
        }
        try assertEqualizer(isPresented: true, in: app)
        try assertPosture(portrait: portrait, folded: folded, in: app)
        attachDiagnostics(in: app, name: posture + " preserved equalizer")

        // Both hiding the inherited sheet and opening another sheet must still target the deck.
        for isPresented in [false, true, false] {
            toggleEqualizer(in: app, expectingPresented: isPresented)
            try assertEqualizer(isPresented: isPresented, in: app)
            try assertPosture(portrait: portrait, folded: folded, in: app)
        }
        attachDiagnostics(in: app, name: posture + " after keyboard toggles")
        let close = app.buttons["phoneDeckClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        waitForMetrics(duoDiagnostic("duoEqualizerMetrics", in: app), timeout: 10) { values in
            values["deckPresented"] as? Bool == false && values["deckSheet"] as? Bool == false
        }
        let final = try metrics(duoDiagnostic("duoEqualizerMetrics", in: app))
        XCTAssertEqual(final["librarySheet"] as? Bool, false)
        XCTAssertEqual(final["inlinePanel"] as? Bool, true, "The saved library panel setting is preserved.")
        try assertPosture(portrait: portrait, folded: folded, in: app)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // No compact override: unfolding must replace the underlying library layout.
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-duo-long-playback",
            "--ui-testing-inline-equalizer",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO",
            "-showLyricsPanel", "NO"
        ]
        app.launch()
        // The simulator can drop the first synthesized key event after launch.
        app.typeKey(.F19, modifierFlags: [])
        return app
    }

    @MainActor private func openDeck(in app: XCUIApplication) {
        let songs = app.buttons["All Songs"]
        XCTAssertTrue(songs.waitForExistence(timeout: 10))
        songs.tap()
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        dock.tap()
        XCTAssertTrue(app.buttons["phoneDeckClose"].waitForExistence(timeout: 5))
    }

    @MainActor private func toggleEqualizer(in app: XCUIApplication, expectingPresented: Bool) {
        let interactive = ProcessInfo.processInfo.environment["DUO_INTERACTIVE_KEYBOARD_TESTS"] == "1"
        if interactive {
            print("DuoKeyboardStep Press Command+Option+E to \(expectingPresented ? "show" : "hide") deck equalizer")
            fflush(nil)
        } else {
            app.typeKey("e", modifierFlags: [.command, .option])
        }
        waitForMetrics(duoDiagnostic("duoEqualizerMetrics", in: app), timeout: interactive ? 120 : 10) { values in
            values["deckSheet"] as? Bool == expectingPresented
        }
    }

    @MainActor private func assertEqualizer(isPresented: Bool, in app: XCUIApplication) throws {
        let diagnostics = duoDiagnostic("duoEqualizerMetrics", in: app)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        let values = try metrics(diagnostics)
        XCTAssertEqual(values["deckPresented"] as? Bool, true)
        XCTAssertEqual(values["deckSheet"] as? Bool, isPresented)
        XCTAssertEqual(values["librarySheet"] as? Bool, false, "The library sheet must stay hidden under the deck.")
        XCTAssertEqual(values["inlinePanel"] as? Bool, true, "The keyboard must not change the saved library panel.")
        XCTAssertEqual(values["commandEnabled"] as? Bool, true)
        XCTAssertEqual(values["menuTitle"] as? String, isPresented ? "Hide Equalizer" : "Show Equalizer")
        let equalizer = app.navigationBars["Equalizer"]
        if isPresented {
            XCTAssertTrue(equalizer.waitForExistence(timeout: 5), "The deck's sheet is visible.")
        } else {
            let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                        object: equalizer)
            wait(for: [disappeared], timeout: 5)
        }
    }

    @MainActor private func assertPosture(portrait: Bool, folded: Bool, in app: XCUIApplication) throws {
        let values = try metrics(duoDiagnostic("duoEqualizerMetrics", in: app))
        XCTAssertEqual(values["layout"] as? String, "expanded")
        XCTAssertEqual(values["portrait"] as? Bool, portrait)
        XCTAssertEqual(values["hasActiveDivision"] as? Bool, folded)
    }

    private func checkpoint(_ posture: String) {
        print("DuoPostureStep \(posture)")
        fflush(nil)
    }

    @MainActor private func waitForMetrics(
        _ element: XCUIElement, timeout: TimeInterval, consecutiveMatches: Int = 1,
        matches: @escaping ([String: Any]) -> Bool
    ) {
        var matchingPolls = 0
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists, let value = element.value as? String, let data = value.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                matchingPolls = 0
                return false
            }
            matchingPolls = matches(values) ? matchingPolls + 1 : 0
            return matchingPolls >= consecutiveMatches
        }, object: nil)
        wait(for: [expected], timeout: timeout)
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor private func attachDiagnostics(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let value = duoDiagnostic("duoEqualizerMetrics", in: app).value as? String ?? "missing"
        let diagnostic = XCTAttachment(string: value)
        diagnostic.name = name + " state"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
    }
}
#endif

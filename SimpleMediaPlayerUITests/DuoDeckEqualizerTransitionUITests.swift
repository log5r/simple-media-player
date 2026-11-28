#if os(iOS)
import Darwin
import UIKit
import XCTest

/// Enable DUO_INTERACTIVE_POSE_TESTS=1 and follow DuoPostureStep in Device Hub.
/// DUO_INTERACTIVE_KEYBOARD_TESTS=1 also leaves Command+Option+E to the operator.
/// DUO_INTERACTIVE_GATE_TOKEN pauses AX queries until the controller creates each printed ready file.
final class DuoDeckEqualizerTransitionUITests: XCTestCase {
    private struct PlaybackIdentity: Equatable {
        let itemID: String
        let queueIDs: [String]
        let generation: UInt64
        let isPaused: Bool
    }

    private var playbackBeforeFolding: PlaybackIdentity?
    private var usesCheckpointGate: Bool {
        ProcessInfo.processInfo.environment["DUO_INTERACTIVE_GATE_TOKEN"] != nil
    }

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
        try checkpoint("Closed portrait")
        waitForMetrics(layout, timeout: 120, consecutiveMatches: 3) { values in
            let insets = values["safeArea"] as? [String: Double] ?? [:]
            return values["layout"] as? String == "compact" && values["portrait"] as? Bool == true
                && insets["leading", default: 0] + insets["trailing", default: 0] > 0
        }
        openDeck(in: app)
        try assertEqualizer(isPresented: false, in: app)
        toggleEqualizer(in: app, expectingPresented: true)
        try assertEqualizer(isPresented: true, in: app)
        playbackBeforeFolding = try playbackIdentity(in: app)

        // Keep the same sheet open across the size-class and posture change.
        try checkpoint(posture + " with deck equalizer open")
        let diagnostics = duoDiagnostic("duoEqualizerMetrics", in: app)
        waitForMetrics(diagnostics, timeout: 120, consecutiveMatches: 3) { values in
            values["layout"] as? String == "expanded" && values["portrait"] as? Bool == portrait
                && values["hasActiveDivision"] as? Bool == folded
        }
        try assertEqualizer(isPresented: true, in: app)
        try assertPosture(portrait: portrait, folded: folded, in: app)
        attachDiagnostics(in: app, name: posture + " preserved equalizer")
        try inspectMenuIfRequested(isPresented: true, in: app, posture: posture, portrait: portrait, folded: folded)

        // Both hiding the inherited sheet and opening another sheet must still target the deck.
        for (index, isPresented) in [false, true, false].enumerated() {
            toggleEqualizer(in: app, expectingPresented: isPresented)
            try assertEqualizer(isPresented: isPresented, in: app)
            try assertPosture(portrait: portrait, folded: folded, in: app)
            if index == 0 {
                try inspectMenuIfRequested(isPresented: false, in: app,
                                          posture: posture, portrait: portrait, folded: folded)
            }
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
        // Prepare the simulator's synthesized input target after launch.
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
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        waitForMetrics(playback, timeout: 10) { $0["playing"] as? Bool == true }
        let pause = app.buttons["phonePlayPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        waitForMetrics(playback, timeout: 10) { $0["paused"] as? Bool == true }
    }

    @MainActor private func toggleEqualizer(in app: XCUIApplication, expectingPresented: Bool) {
        let interactive = ProcessInfo.processInfo.environment["DUO_INTERACTIVE_KEYBOARD_TESTS"] == "1"
        if interactive {
            print("DuoKeyboardStep Press Command+Option+E to \(expectingPresented ? "show" : "hide") deck equalizer")
            fflush(nil)
        } else {
            // Prepare synthesized input after a deck or display change; send the command itself once.
            app.typeKey(.F19, modifierFlags: [])
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
        let expected = try XCTUnwrap(playbackBeforeFolding)
        XCTAssertEqual(try playbackIdentity(in: app), expected, "Folding and EQ commands must keep the same playback.")
    }

    @MainActor private func playbackIdentity(in app: XCUIApplication) throws -> PlaybackIdentity {
        let values = try metrics(duoDiagnostic("duoPlaybackMetrics", in: app))
        let itemID = try XCTUnwrap(values["itemID"] as? String)
        let queueIDs = try XCTUnwrap(values["queueIDs"] as? [String])
        XCTAssertFalse(itemID.isEmpty, "The deck must have a current item before folding.")
        XCTAssertTrue(queueIDs.contains(itemID), "The playback queue must contain the current item.")
        return PlaybackIdentity(
            itemID: itemID, queueIDs: queueIDs,
            generation: try XCTUnwrap(values["generation"] as? NSNumber).uint64Value,
            isPaused: try XCTUnwrap(values["paused"] as? Bool)
        )
    }

    @MainActor private func inspectMenuIfRequested(
        isPresented: Bool, in app: XCUIApplication, posture: String, portrait: Bool, folded: Bool
    ) throws {
        guard usesCheckpointGate else { return }
        let title = isPresented ? "Hide Equalizer" : "Show Equalizer"
        try checkpoint("Inspect \(title) in \(posture)", marker: "DuoMenuStep")
        try assertEqualizer(isPresented: isPresented, in: app)
        try assertPosture(portrait: portrait, folded: folded, in: app)
    }

    private func checkpoint(_ step: String, marker: String = "DuoPostureStep") throws {
        print("\(marker) \(step)")
        fflush(nil)
        guard let token = ProcessInfo.processInfo.environment["DUO_INTERACTIVE_GATE_TOKEN"] else { return }
        let safeToken = token.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined().prefix(32)
        let readyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("duo-\(safeToken)-\(UUID().uuidString).ready")
        let files = FileManager.default
        if files.fileExists(atPath: readyFile.path) { try files.removeItem(at: readyFile) }
        print("DuoInteractiveGate \(readyFile.path)")
        fflush(nil)
        // This waits in the test runner only. Simulator AX polling resumes after the host finishes its UI actions.
        let deadline = ProcessInfo.processInfo.systemUptime + 600
        while !files.fileExists(atPath: readyFile.path), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard files.fileExists(atPath: readyFile.path) else {
            throw NSError(domain: "DuoInteractiveGate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Timed out after 600 seconds waiting for the controller to create "
                    + readyFile.path + " after completing: " + step
            ])
        }
        try files.removeItem(at: readyFile)
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

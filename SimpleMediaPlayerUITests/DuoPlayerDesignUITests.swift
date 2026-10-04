#if os(iOS)
import UIKit
import XCTest

/// Select the actual Open or Book posture and orientation in Device Hub before each case.
/// These tests observe scene geometry and never request synthetic XCTest rotation.
final class DuoPlayerDesignUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the Duo phone layout.")
    }

    @MainActor func testLandscapeLEDConsumesRightHalf() throws {
        let app = try launch(portrait: false)
        let geometry = try metrics(duoDiagnostic("duoLayoutMetrics", in: app))
        try XCTSkipIf(geometry["hasActiveDivision"] as? Bool == true, "Select Open landscape for the half-width case.")
        let led = try regionFrame("expandedLEDRegion", in: app)
        let controls = try regionFrame("expandedControlsRegion", in: app)
        let width = try number("width", in: geometry)
        XCTAssertEqual(led.width, width / 2, accuracy: 2)
        XCTAssertEqual(controls.width, width / 2, accuracy: 2)
        XCTAssertEqual(led.maxX, controls.minX + width, accuracy: 2)
        XCTAssertEqual(led.minX, controls.maxX, accuracy: 2)
        XCTAssertEqual(led.minY, controls.minY, accuracy: 2)
        XCTAssertEqual(led.height, controls.height, accuracy: 2)
        assertPlaybackTargets(in: app, containedIn: controls)
        assertVolumeRowFillsControls(in: app, controls: controls, inset: 8)
        attach(app, name: "Duo Open landscape LED right half")
    }

    @MainActor func testPortraitVisualsStayAboveControlsAndLibraryReturns() throws {
        let app = try launch(portrait: true)
        let original = try metrics(duoDiagnostic("duoPlaybackMetrics", in: app))
        let led = try regionFrame("duoPortraitLED", in: app)
        let meters = try regionFrame("duoPortraitMeters", in: app)
        let controls = try regionFrame("duoPortraitControls", in: app)
        let geometry = try metrics(duoDiagnostic("duoLayoutMetrics", in: app))
        try assertPortraitAllocation(in: app, geometry: geometry, led: led, meters: meters, controls: controls)
        let lamp = element("indicatorEQ", in: app)
        XCTAssertTrue(lamp.exists)
        XCTAssertTrue(meters.insetBy(dx: -2, dy: -2).contains(lamp.frame))
        assertPlaybackTargets(in: app, containedIn: controls)
        assertVolumeRowFillsControls(in: app, controls: controls, inset: 20)
        attach(app, name: "Duo portrait LED above meters and controls")

        let library = app.buttons["duoShowLibrary"]
        assertTouchTarget(library, in: app, containedIn: controls)
        library.tap()
        let close = app.buttons["duoCloseLibrary"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let track = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'libraryTrack.'")
        ).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        assertTouchTarget(close, in: app)
        close.tap()
        XCTAssertTrue(app.buttons["duoShowLibrary"].waitForExistence(timeout: 5))
        try assertPlaybackPreserved(original, in: app)
        let settings = app.buttons["settingsButton"]
        assertTouchTarget(settings, in: app, containedIn: controls)
        settings.tap()
        let settingsClose = app.buttons["settingsCloseButton"]
        XCTAssertTrue(settingsClose.waitForExistence(timeout: 5))
        settingsClose.tap()
        XCTAssertTrue(app.buttons["duoShowLibrary"].waitForExistence(timeout: 5))
        try assertPlaybackPreserved(original, in: app)
        attach(app, name: "Duo portrait playback after Library and Settings")
    }

    @MainActor func testLibrarySurvivesRealRotationFromPortrait() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUO_INTERACTIVE_ORIENTATION_TESTS"] == "1",
                          "Enable interactive Device Hub rotation for this case.")
        let app = try launch(portrait: true)
        let original = try metrics(duoDiagnostic("duoPlaybackMetrics", in: app))
        rotateDuo(to: .landscapeLeft, in: app, interactiveTimeout: 120)
        let track = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'libraryTrack.' AND label CONTAINS %@", "Layout Track 1")
        ).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        try assertPlaybackPreserved(original, in: app)
        attach(app, name: "Duo landscape library after portrait rotation")
        rotateDuo(to: .portrait, in: app, interactiveTimeout: 120)
        let library = app.buttons["duoShowLibrary"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        app.buttons["duoCloseLibrary"].tap()
        try assertPlaybackPreserved(original, in: app)
        attach(app, name: "Duo portrait library after landscape return")
    }

    @MainActor private func launch(portrait: Bool) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-reset-led-settings",
            "--ui-testing-duo-autoplay-probe", "--ui-testing-audible-layout", "--ui-testing-duo-long-playback",
            "-bottomPanelLayout", "classic", "-ledPanelSide", "left",
            "-mediaListColumnOrder", "index,title,artist,album,duration",
            "-mediaListVisibleColumns", "index,title,artist,album,duration",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let geometry = try metrics(layout)
        try XCTSkipIf((geometry["division"] as? [[String: Any]] ?? []).isEmpty, "Run on iPhone Duo in Device Hub.")
        try XCTSkipUnless(
            geometry["portrait"] as? Bool == portrait, "Select the case's real orientation in Device Hub."
        )
        XCTAssertEqual(geometry["layout"] as? String, "expanded", "Select Open or Book before running this case.")
        XCTAssertEqual(geometry["horizontalSizeClass"] as? String, "regular")
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "\"playing\":true"), object: playback
        )
        wait(for: [playing], timeout: 10)
        return app
    }

    @MainActor private func assertPlaybackTargets(in app: XCUIApplication, containedIn frame: CGRect) {
        for identifier in [
            "previousTrackButton", "playButton", "pauseButton", "stopButton", "nextTrackButton",
            "pitchButton", "speedButton", "volumeUpButton", "volumeDownButton", "phoneMute"
        ] {
            assertTouchTarget(app.buttons[identifier], in: app, containedIn: frame)
        }
    }

    @MainActor private func assertVolumeRowFillsControls(in app: XCUIApplication, controls: CGRect, inset: CGFloat) {
        let volume = element("volumeControl", in: app)
        let mute = app.buttons["phoneMute"]
        let route = element("phoneRoutePicker", in: app)
        let slider = element("volumeLevel", in: app)
        XCTAssertTrue(volume.exists)
        assertTouchTarget(route, in: app, containedIn: controls)
        XCTAssertEqual(volume.frame.minX, controls.minX + inset, accuracy: 2)
        XCTAssertEqual(volume.frame.maxX + 8, mute.frame.minX, accuracy: 2)
        XCTAssertEqual(mute.frame.maxX + 8, route.frame.minX, accuracy: 2)
        XCTAssertEqual(route.frame.maxX, controls.maxX - inset, accuracy: 2)
        XCTAssertGreaterThanOrEqual(slider.frame.width + 0.001, 44)
        XCTAssertEqual(slider.frame.minX, app.buttons["volumeDownButton"].frame.maxX + 6, accuracy: 2)
        XCTAssertEqual(slider.frame.maxX, app.buttons["volumeUpButton"].frame.minX - 6, accuracy: 2)
    }

    @MainActor private func assertTouchTarget(
        _ element: XCUIElement, in app: XCUIApplication, containedIn frame: CGRect? = nil
    ) {
        XCTAssertTrue(element.exists, element.identifier)
        // Ignore subpixel floating-point roundoff at fractional Book coordinates.
        XCTAssertGreaterThanOrEqual(element.frame.width + 0.001, 44, element.identifier)
        XCTAssertGreaterThanOrEqual(element.frame.height + 0.001, 44, element.identifier)
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(element.frame), element.identifier)
        if let frame {
            XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(element.frame), element.identifier)
        }
    }

    @MainActor private func assertPlaybackPreserved(_ original: [String: Any], in app: XCUIApplication) throws {
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        let current = try metrics(playback)
        XCTAssertEqual(current["itemID"] as? String, original["itemID"] as? String)
        XCTAssertEqual(current["queueIDs"] as? [String], original["queueIDs"] as? [String])
        XCTAssertEqual(current["playing"] as? Bool, true)
        for key in ["generation", "volume", "pitch", "rate"] {
            XCTAssertEqual(try number(key, in: current), try number(key, in: original), key)
        }
        XCTAssertGreaterThan(try number("time", in: current), try number("time", in: original))
        XCTAssertGreaterThan(try number("rmsL", in: current), 0)
        XCTAssertGreaterThan(try number("rmsR", in: current), 0)
    }

    @MainActor private func assertPortraitAllocation(
        in app: XCUIApplication, geometry: [String: Any], led: CGRect, meters: CGRect, controls: CGRect
    ) throws {
        let root = try sceneContentFrame(in: app, geometry: geometry)
        let occlusions = try activeRegions("occlusion", in: geometry, origin: root.origin)
        try XCTSkipIf(occlusions.contains { $0.intersects(root) }, "Active occlusion needs a separate UI case.")
        let divisions = try activeRegions("division", in: geometry, origin: root.origin)
            .filter { $0.intersects(root) }
        let hinges = divisions.filter { $0.width > $0.height && $0.width >= root.width / 2 }
        try XCTSkipIf(hinges.count != divisions.count, "Other division axes need a separate UI case.")
        try XCTSkipIf(hinges.count > 1, "Multiple active horizontal divisions need a separate UI case.")
        let upperEnd = hinges.first?.minY ?? root.midY
        let lowerStart = hinges.first?.maxY ?? root.midY
        XCTAssertEqual(led.width, root.width, accuracy: 2)
        XCTAssertEqual(meters.width, root.width, accuracy: 2)
        XCTAssertEqual(led.height, meters.height, accuracy: 2)
        XCTAssertEqual(led.minY, root.minY, accuracy: 2)
        XCTAssertEqual(led.maxY, meters.minY, accuracy: 2)
        XCTAssertEqual(meters.maxY, upperEnd, accuracy: 2)
        XCTAssertEqual(controls.minY, lowerStart, accuracy: 2)
        XCTAssertEqual(controls.maxY, root.maxY, accuracy: 2)
    }

    @MainActor private func sceneContentFrame(in app: XCUIApplication, geometry: [String: Any]) throws -> CGRect {
        let safeArea = geometry["safeArea"] as? [String: Any] ?? [:]
        let width = try number("width", in: geometry)
        let height = try number("height", in: geometry)
        let top = try number("top", in: safeArea)
        let bottom = try number("bottom", in: safeArea)
        let leading = try number("leading", in: safeArea)
        let trailing = try number("trailing", in: safeArea)
        try XCTSkipUnless(abs(app.frame.width - width - leading - trailing) < 2 &&
            abs(app.frame.height - height - top - bottom) < 2, "Root and screen coordinate bounds differ.")
        return CGRect(x: app.frame.minX + CGFloat(leading), y: app.frame.minY + CGFloat(top),
                      width: width, height: height)
    }

    private func activeRegions(_ kind: String, in geometry: [String: Any], origin: CGPoint) throws -> [CGRect] {
        let regions = geometry[kind] as? [[String: Any]] ?? []
        return try regions.filter { $0["active"] as? Bool == true }.map { region in
            let margin = region["margins"] as? [String: Any] ?? [:]
            let leading = try number("leading", in: margin)
            let top = try number("top", in: margin)
            return CGRect(
                x: origin.x + CGFloat(try number("x", in: region) - leading),
                y: origin.y + CGFloat(try number("y", in: region) - top),
                width: try number("width", in: region) + leading + number("trailing", in: margin),
                height: try number("height", in: region) + top + number("bottom", in: margin)
            )
        }
    }

    @MainActor private func regionFrame(_ regionID: String, in app: XCUIApplication) throws -> CGRect {
        let diagnostic = duoDiagnostic("\(regionID)Metrics", in: app)
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5), regionID)
        let values = try metrics(diagnostic)
        let frame = try CGRect(x: number("x", in: values), y: number("y", in: values),
                               width: number("width", in: values), height: number("height", in: values))
        XCTAssertGreaterThan(frame.width, 0, regionID)
        XCTAssertGreaterThan(frame.height, 0, regionID)
        return frame
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let container = app.otherElements.matching(identifier: identifier).firstMatch
        if container.exists { return container }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func number(_ key: String, in values: [String: Any]) throws -> Double {
        try XCTUnwrap(values[key] as? Double)
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for identifier in ["duoLayoutMetrics", "duoPlaybackMetrics"] {
            let attachment = XCTAttachment(string: duoDiagnostic(identifier, in: app).value as? String ?? "missing")
            attachment.name = "\(name) \(identifier)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
#endif

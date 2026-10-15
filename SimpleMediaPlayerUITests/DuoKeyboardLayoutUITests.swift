#if os(iOS)
import UIKit
import XCTest

/// Run on the actual Open or Book portrait posture in Device Hub.
/// Turn off I/O > Keyboard > Connect Hardware Keyboard in Simulator to verify the software keyboard layout.
final class DuoKeyboardLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the Duo phone layout.")
    }

    @MainActor func testPortraitLibrarySurvivesSearchKeyboardPresentationAndDismissal() throws {
        let app = try launchPortrait()
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        app.buttons["pauseButton"].tap()
        waitForValue("\"paused\":true", in: playback)
        let originalPlayback = try metrics(playback)
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        let originalLayout = try metrics(layout)
        // Book places the Library below the fold; Open has no horizontal fold and keeps it full height.
        let foldBottom = try self.foldBottom(in: originalLayout)

        app.buttons["duoShowLibrary"].tap()
        let closeLibrary = app.buttons["duoCloseLibrary"]
        XCTAssertTrue(closeLibrary.waitForExistence(timeout: 5))
        try waitForLibrary(top: foldBottom, in: originalLayout, app: app)
        // Portrait hides the sidebar column, so search must stay in the Library's detail column.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        search.tap()
        let showsSoftwareKeyboard = try verifyKeyboardLayout(
            original: originalLayout, foldBottom: foldBottom, in: app
        )
        XCTAssertTrue(closeLibrary.exists, "The keyboard must not switch the portrait Library to another layout.")

        search.typeText("Layout Track 2")
        let secondTrack = track("Layout Track 2", in: app)
        XCTAssertTrue(secondTrack.waitForExistence(timeout: 10))
        waitForDisappearance(track("Layout Track 1", in: app))
        XCTAssertTrue(closeLibrary.exists)
        XCTAssertTrue(search.isHittable, "Search must remain above the keyboard.")

        let cancelSearch = app.buttons["close"].firstMatch
        XCTAssertTrue(cancelSearch.waitForExistence(timeout: 5))
        cancelSearch.tap()
        waitForDisappearance(app.keyboards.firstMatch)
        waitForValue("\"portrait\":true", in: layout)
        XCTAssertTrue(closeLibrary.exists, "Dismissing the keyboard must preserve the open Library.")
        XCTAssertFalse(app.buttons["duoShowLibrary"].exists)
        XCTAssertTrue(track("Layout Track 1", in: app).waitForExistence(timeout: 10))
        try waitForLibrary(top: foldBottom, in: originalLayout, app: app)

        let currentPlayback = try metrics(playback)
        XCTAssertEqual(currentPlayback["itemID"] as? String, originalPlayback["itemID"] as? String)
        XCTAssertEqual(currentPlayback["queueIDs"] as? [String], originalPlayback["queueIDs"] as? [String])
        XCTAssertEqual(try number("generation", in: currentPlayback), try number("generation", in: originalPlayback))
        XCTAssertEqual(currentPlayback["paused"] as? Bool, true)
        closeLibrary.tap()
        XCTAssertTrue(app.buttons["duoShowLibrary"].waitForExistence(timeout: 5))
        try XCTSkipUnless(
            showsSoftwareKeyboard,
            "Search passed, but a connected hardware keyboard kept the software keyboard layout unverified."
        )
    }

    /// Returns false when a connected hardware keyboard leaves the software keyboard below the window.
    @MainActor private func verifyKeyboardLayout(
        original: [String: Any], foldBottom: CGFloat?, in app: XCUIApplication
    ) throws -> Bool {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        guard waitUntil(timeout: 3, { keyboard.frame.minY < window.maxY }) else {
            try waitForLibrary(top: foldBottom, in: original, app: app)
            return false
        }
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        waitForValue("\"portrait\":false", in: layout)
        let keyboardLayout = try metrics(layout)
        XCTAssertLessThan(try number("height", in: keyboardLayout), try number("width", in: keyboardLayout))
        XCTAssertEqual(try number("width", in: keyboardLayout), try number("width", in: original), accuracy: 1)
        // Too little room remains below the fold, so the Library uses the full height above the keyboard.
        try waitForLibrary(top: nil, in: keyboardLayout, app: app)
        return true
    }

    @MainActor private func launchPortrait() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout",
            "--ui-testing-duo-autoplay-probe", "--ui-testing-duo-long-playback",
            "-mediaListColumnOrder", "index,title,artist,album,duration",
            "-mediaListVisibleColumns", "index,title,artist,album,duration",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let geometry = try metrics(layout)
        try XCTSkipIf((geometry["division"] as? [[String: Any]] ?? []).isEmpty, "Run on iPhone Duo in Device Hub.")
        try XCTSkipUnless(geometry["portrait"] as? Bool == true, "Select the actual portrait posture in Device Hub.")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(geometry["layout"] as? String, "expanded")
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        waitForValue("\"title\":\"Layout Track 1\"", in: playback)
        waitForValue("\"playing\":true", in: playback)
        XCTAssertTrue(app.buttons["pauseButton"].waitForExistence(timeout: 5))
        return app
    }

    /// The global lower edge of an active horizontal fold; division frames use the root's local coordinates.
    private func foldBottom(in layout: [String: Any]) throws -> CGFloat? {
        let root = try rootFrame(in: layout)
        let divisions = try (layout["division"] as? [[String: Any]] ?? [])
            .filter { $0["active"] as? Bool == true }
            .map { region in
                try CGRect(x: root.minX + number("x", in: region), y: root.minY + number("y", in: region),
                           width: number("width", in: region), height: number("height", in: region))
            }
        return divisions.filter { $0.width > $0.height && $0.intersects(root) }.map(\.maxY).max()
    }

    private func rootFrame(in layout: [String: Any]) throws -> CGRect {
        try CGRect(x: number("globalX", in: layout), y: number("globalY", in: layout),
                   width: number("width", in: layout), height: number("height", in: layout))
    }

    /// Waits for the Library to span from `top`, or the root's top edge, to the root's bottom edge.
    @MainActor private func waitForLibrary(
        top: CGFloat?, in layout: [String: Any], app: XCUIApplication
    ) throws {
        let root = try rootFrame(in: layout)
        let expectedTop = top ?? root.minY
        let diagnostic = duoDiagnostic("duoPortraitLibraryMetrics", in: app)
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
        let placed = waitUntil(timeout: 5) {
            guard let frame = try? libraryFrame(diagnostic) else { return false }
            return abs(frame.minY - expectedTop) <= 2 && abs(frame.maxY - root.maxY) <= 2
        }
        let frame = try libraryFrame(diagnostic)
        XCTAssertTrue(placed, "Library \(frame) should span \(expectedTop)–\(root.maxY).")
    }

    @MainActor private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "Layout update")], timeout: 0.2)
        }
        return true
    }

    @MainActor private func libraryFrame(_ diagnostic: XCUIElement) throws -> CGRect {
        let values = try metrics(diagnostic)
        return try CGRect(x: number("x", in: values), y: number("y", in: values),
                          width: number("width", in: values), height: number("height", in: values))
    }

    @MainActor private func track(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'libraryTrack.' AND label CONTAINS %@", title
        )).firstMatch
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

    @MainActor private func waitForDisappearance(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        wait(for: [expectation], timeout: 10)
    }
}
#endif

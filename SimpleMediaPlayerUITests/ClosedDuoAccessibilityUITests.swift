#if os(iOS)
import UIKit
import XCTest

/// Select Closed portrait in Device Hub and set DUO_VOICEOVER_TESTS=1 for the test runner.
final class ClosedDuoAccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUO_VOICEOVER_TESTS"] == "1",
                          "Enable explicitly to run with VoiceOver.")
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Run on the Duo's Closed display.")
    }

    @MainActor func testVoiceOverNavigatesLibraryAndPlaybackDeck() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-long-playback",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-volumeNormalizationEnabled", "NO", "-sectionNavigationEnabled", "NO"
        ]
        app.launch()
        let window = app.frame
        try XCTSkipUnless(abs(window.width - 466) < 2 && abs(window.height - 678) < 2,
                          "Select the 466 × 678 pt Closed portrait display in Device Hub.")
        let voiceOver = XCUIDevice.shared.voiceOverService
        let wasEnabled = voiceOver.isEnabled
        if !wasEnabled {
            addTeardownBlock { @MainActor in
                if voiceOver.isEnabled { try voiceOver.disable() }
            }
            try voiceOver.enable()
        }
        XCTAssertTrue(voiceOver.isEnabled)

        try playTrack(in: app, voiceOver: voiceOver)
        try verifyDeck(in: app, voiceOver: voiceOver)
    }

    @MainActor private func playTrack(in app: XCUIApplication, voiceOver: XCUIVoiceOverService) throws {
        let overflow = app.toolbarOverflowButton()
        XCTAssertTrue(overflow.waitForExistence(timeout: 5))
        try focus(overflow, saying: overflow.label, voiceOver: voiceOver)

        let songs = app.buttons["All Songs"]
        try focus(songs, saying: "All Songs", voiceOver: voiceOver)
        try assertSpeech(voiceOver.moveForward(), contains: "Albums", step: "After All Songs")
        try assertSpeech(voiceOver.moveBackward(), contains: "All Songs", step: "Back to All Songs")
        songs.doubleTap()

        let track = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'phoneTrack.' AND label CONTAINS %@", "Layout Track 2"
        )).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        try focus(track, saying: "Layout Track 2", voiceOver: voiceOver)
        try assertSpeech(voiceOver.currentSpeech(), contains: "Layout Artist", step: "Track artist")
        track.doubleTap()

        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        try focus(dock, saying: "Now Playing", voiceOver: voiceOver)
        try assertSpeech(voiceOver.currentSpeech(), contains: "Layout Track 2", step: "Now Playing track")
        dock.doubleTap()
    }

    @MainActor private func verifyDeck(in app: XCUIApplication, voiceOver: XCUIVoiceOverService) throws {
        let close = app.buttons["phoneDeckClose"]
        let playPause = app.buttons["phonePlayPause"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "Pause", timeout: 5))
        try focus(app.buttons["phoneStop"], saying: "Stop", voiceOver: voiceOver)
        try assertSpeech(voiceOver.moveForward(), contains: "Previous Track", step: "After Stop")
        try assertSpeech(voiceOver.moveForward(), contains: "Pause", step: "After Previous Track")
        playPause.doubleTap()
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "Play", timeout: 5))

        let lyrics = app.buttons["phonePage.Lyrics"]
        try focus(lyrics, saying: "Lyrics", voiceOver: voiceOver)
        lyrics.doubleTap()
        XCTAssertTrue(app.staticTexts["First lyric"].waitForExistence(timeout: 5))
        try focus(app.buttons["Edit Lyrics…"], saying: "Edit Lyrics", voiceOver: voiceOver)
        try focus(close, saying: "Close", voiceOver: voiceOver)
        close.doubleTap()
        XCTAssertTrue(close.wait(for: \.exists, toEqual: false, timeout: 5))
        XCTAssertTrue(app.buttons["phoneLEDDock"].isHittable)
    }

    @MainActor private func focus(
        _ element: XCUIElement, saying expected: String, voiceOver: XCUIVoiceOverService
    ) throws {
        XCTAssertTrue(element.isHittable, expected)
        // Tap once to select the element for VoiceOver without activating it.
        element.tap()
        try assertSpeech(voiceOver.currentSpeech(), contains: expected, step: "Focus \(expected)")
    }

    @MainActor private func assertSpeech(
        _ output: XCUIVoiceOverService.Output, contains expected: String, step: String
    ) {
        let attachment = XCTAttachment(string: output.utterance)
        attachment.name = step
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(expected.isEmpty, step)
        XCTAssertTrue(output.utterance.localizedCaseInsensitiveContains(expected), "\(step): \(output.utterance)")
    }
}
#endif

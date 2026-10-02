#if os(iOS)
import UIKit
import XCTest

final class IPhoneLibraryWorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "This suite verifies the phone layout.")
    }

    @MainActor func testSettingsAndBulkEditing() {
        let app = launch()
        app.buttons["phoneLibraryMore"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["settingsCloseButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Panel Layout"].exists)
        XCTAssertFalse(app.buttons["Edit Columns"].exists)
        app.buttons["settingsCloseButton"].tap()
        app.buttons["All Songs"].tap()
        app.buttons["phoneTrackMore"].tap()
        app.buttons["multipleEditButton"].tap()
        let tracks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'"))
        tracks.element(boundBy: 0).tap()
        tracks.element(boundBy: 1).tap()
        app.buttons["editSelectedMediaButton"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["bulkEditSelectionSummary"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["phoneTrackMore"].waitForExistence(timeout: 5))
    }

    @MainActor func testPlaylistAddRenameAndRemove() {
        let app = launch()
        app.tabBars.buttons["Playlists"].tap()
        app.buttons["addPlaylistButton"].tap()
        app.buttons["Add Tracks"].tap()
        let track = app.buttons.containing(.staticText, identifier: "Layout Track 1").firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Layout Track 1"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["New Playlist"].press(forDuration: 1)
        app.buttons["Rename"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" Renamed")
        app.alerts.buttons["Rename"].tap()
        let renamed = app.buttons["New Playlist Renamed"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        renamed.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).firstMatch
        row.press(forDuration: 1)
        app.buttons["Remove from Playlist"].tap()
        XCTAssertTrue(app.staticTexts["No Media"].waitForExistence(timeout: 5))
    }

    @MainActor func testExportUsesShareSheet() {
        let app = launch()
        app.buttons["phoneLibraryMore"].tap()
        app.buttons["Export…"].tap()
        XCTAssertTrue(app.buttons["Fill All Names with Timestamps"].waitForExistence(timeout: 10))
        app.buttons["Fill All Names with Timestamps"].tap()
        app.buttons["Fill with Timestamps"].tap()
        app.buttons["Export"].tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15), app.debugDescription)
        let close = app.buttons["header.closeButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["phoneLibraryMore"].waitForExistence(timeout: 5))
        XCTAssertFalse(shareSheet.exists)
        app.buttons["phoneLibraryMore"].tap()
        XCTAssertTrue(app.buttons["Export…"].isEnabled)
    }

    @MainActor func testEnglishLyricsEditorFitsPhoneScreen() {
        verifyLyricsEditor(language: "en")
    }

    @MainActor func testJapaneseLyricsEditorFitsPhoneScreen() {
        verifyLyricsEditor(language: "ja")
    }

    @MainActor private func verifyLyricsEditor(language: String) {
        let app = launch(language: language)
        let isJapanese = language == "ja"
        app.buttons[isJapanese ? "すべての曲" : "All Songs"].tap()
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneTrack.'")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        let dock = app.buttons["phoneLEDDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        dock.tap()
        app.buttons["phonePage.Lyrics"].tap()
        let edit = app.navigationBars.buttons[isJapanese ? "歌詞を編集…" : "Edit Lyrics…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let editor = app.textViews[isJapanese ? "歌詞" : "Lyrics"]
        let cancel = app.buttons[isJapanese ? "キャンセル" : "Cancel"]
        let save = app.buttons[isJapanese ? "保存" : "Save"]
        for element in [
            editor, cancel, save,
            app.buttons[isJapanese ? "アプリ内のみ" : "App Only"],
            app.buttons[isJapanese ? "タグに埋め込む" : "Embed in File"]
        ] {
            XCTAssertTrue(element.waitForExistence(timeout: 5))
            XCTAssertTrue(app.frame.contains(element.frame), "Control extends beyond the screen: \(element.label)")
        }
        XCTAssertTrue(editor.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(save.isHittable)
        cancel.tap()
        waitForDisappearance(editor)
        edit.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        waitForDisappearance(editor)
    }

    @MainActor private func waitForDisappearance(_ element: XCUIElement) {
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        wait(for: [disappeared], timeout: 5)
    }

    @MainActor private func launch(language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            "-volumeNormalizationEnabled", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["phoneLibraryMore"].waitForExistence(timeout: 10))
        return app
    }
}
#endif

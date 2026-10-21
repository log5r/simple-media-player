#if os(iOS)
import UIKit
import XCTest

/// The Duo player's rows follow the phone deck: one 16 pt column, 44 pt rows, and Mute | slot | AirPlay.
extension DuoPlayerDesignUITests {
    /// The Duo player's volume row is the phone deck's Mute | slot | AirPlay; the bottom panel keeps − and +.
    @MainActor func assertPlaybackTargets(
        in app: XCUIApplication, containedIn frame: CGRect, deckVolumeRow: Bool = false
    ) {
        let volumeButtons = deckVolumeRow ? [] : ["volumeUpButton", "volumeDownButton"]
        for identifier in [
            "previousTrackButton", "playButton", "pauseButton", "stopButton", "nextTrackButton",
            "pitchButton", "speedButton", "phoneMute"
        ] + volumeButtons {
            assertTouchTarget(app.buttons[identifier], in: app, containedIn: frame)
        }
        if deckVolumeRow {
            XCTAssertFalse(app.buttons["volumeUpButton"].exists)
            XCTAssertFalse(app.buttons["volumeDownButton"].exists)
            assertTouchTarget(element("phoneRoutePicker", in: app), in: app, containedIn: frame)
        }
    }

    /// The LED plate, seek row, control rows, and navigation share one 16 pt column; the rows are 44 pt.
    @MainActor func assertPortraitColumn(in app: XCUIApplication, controls: CGRect, folded: Bool) throws {
        let plate = try regionFrame("duoPortraitLEDPlate", in: app)
        let seek = try regionFrame("duoPortraitSeek", in: app)
        let navigation = ["duoShowLibrary", "equalizerButton", "lyricsButton", "settingsButton"].map {
            app.buttons[$0].frame
        }
        let rows: [(String, CGRect)] = [
            ("seek", seek),
            ("transport", app.buttons["pitchButton"].frame.union(app.buttons["nextTrackButton"].frame)),
            ("volume", element("volumeControl", in: app).frame),
            ("navigation", navigation.reduce(navigation[0]) { $0.union($1) })
        ]
        XCTAssertEqual(plate.minX, controls.minX + 16, accuracy: 1)
        XCTAssertEqual(plate.maxX, controls.maxX - 16, accuracy: 1)
        for (name, frame) in rows {
            XCTAssertEqual(frame.minX, plate.minX, accuracy: 1, "\(name) leading edge")
            XCTAssertEqual(frame.maxX, plate.maxX, accuracy: 1, "\(name) trailing edge")
            XCTAssertEqual(frame.height, 44, accuracy: 1, "\(name) height")
        }
        for frame in navigation {
            XCTAssertEqual(frame.minY, navigation[0].minY, accuracy: 1, "Navigation cells share one row")
            XCTAssertEqual(frame.width, navigation[0].width, accuracy: 1, "Navigation cells are equal")
        }
        // The controls start 16 pt below their top edge rather than centering in the lower half.
        XCTAssertEqual(seek.minY, controls.minY + 16, accuracy: 1)
        if !folded {
            XCTAssertEqual(navigation[0].maxY, controls.maxY - 16, accuracy: 1, "Spare height goes to the visuals")
        }
        assertDeckVolumeRow(in: app, row: element("volumeControl", in: app).frame)
    }

    @MainActor func assertDeckVolumeRow(in app: XCUIApplication, row: CGRect) {
        let mute = app.buttons["phoneMute"].frame
        let slider = element("volumeLevel", in: app).frame
        let route = element("phoneRoutePicker", in: app).frame
        XCTAssertEqual(mute.minX, row.minX, accuracy: 1)
        XCTAssertEqual(slider.minX, mute.maxX + 8, accuracy: 1)
        XCTAssertEqual(route.minX, slider.maxX + 8, accuracy: 1)
        XCTAssertEqual(route.maxX, row.maxX, accuracy: 1, "AirPlay ends the volume row")
        XCTAssertEqual(route.width, 44, accuracy: 1)
    }
}
#endif

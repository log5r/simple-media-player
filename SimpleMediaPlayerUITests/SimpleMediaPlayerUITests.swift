//
//  SimpleMediaPlayerUITests.swift
//  SimpleMediaPlayerUITests
//
//  Created by Judau on 2026/07/04.
//

import XCTest

final class SimpleMediaPlayerUITests: XCTestCase {
    #if os(macOS)

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests
        // before they run. The setUp method is a good place to do this.
    }

    // Keyboard and mouse workflows use the desktop list.
    // Phone workflows are covered by IPhoneLibraryWorkflowUITests.
    @MainActor
    func testCreatingPlaylistsUsesUniqueNames() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()

        let addPlaylistButton = app.buttons["addPlaylistButton"]
        if !addPlaylistButton.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(addPlaylistButton.waitForExistence(timeout: 5))

        addPlaylistButton.click()
        XCTAssertTrue(
            localizedPlaylist(named: "New Playlist", japaneseName: "新規プレイリスト", in: app).waitForExistence(timeout: 2)
        )

        addPlaylistButton.click()
        XCTAssertTrue(
            localizedPlaylist(named: "New Playlist 2", japaneseName: "新規プレイリスト 2", in: app).waitForExistence(timeout: 2)
        )
    }

    @MainActor
    func testFourItemsPerSecondKeepsEverySelectedRow() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "--ui-testing-media-count=50",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()

        let multipleEditButton = app.buttons["multipleEditButton"]
        if !multipleEditButton.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(multipleEditButton.waitForExistence(timeout: 5))
        multipleEditButton.click()

        let status = app.descendants(matching: .any)["bulkSelectionStatus"]
        let rapidSelectionButton = app.buttons["rapidSelectionTestButton"]
        let rapidSelectionDuration = app.descendants(matching: .any)["rapidSelectionDuration"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(rapidSelectionButton.waitForExistence(timeout: 2))
        XCTAssertTrue(rapidSelectionDuration.waitForExistence(timeout: 2))

        let rowOrder = [7, 10, 3, 4, 8, 1, 6, 9]
        let rows = rowOrder.map { app.descendants(matching: .any)["mediaRow.\($0)"] }

        rapidSelectionButton.click()
        expectation(
            for: NSPredicate(format: "value != %@", "pending"),
            evaluatedWith: rapidSelectionDuration
        )
        // A large table makes macOS accessibility snapshots slow even though the
        // in-app click cadence remains 250 ms, so allow time for the updated value to surface.
        waitForExpectations(timeout: 15)

        XCTAssertEqual(status.value as? String, "\(rowOrder.count)")
        let elapsedMilliseconds = try XCTUnwrap(rapidSelectionDuration.value as? String)
        let elapsed = try XCTUnwrap(Double(elapsedMilliseconds)) / 1_000
        let clickRate = Double(rowOrder.count - 1) / elapsed
        XCTAssertGreaterThanOrEqual(clickRate, 3.5)
        XCTAssertLessThanOrEqual(clickRate, 4.5)
        for row in rows {
            XCTAssertTrue(row.exists)
            XCTAssertTrue(row.isSelected)
        }
    }

    @MainActor
    func testMultipleSelectionKeepsEverySelectedRow() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()

        let multipleEditButton = app.buttons["multipleEditButton"]
        if !multipleEditButton.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        guard multipleEditButton.waitForExistence(timeout: 5) else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Multiple edit button lookup failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Multiple edit button was not found.\n\(app.debugDescription)")
            return
        }
        multipleEditButton.click()

        let status = app.descendants(matching: .any)["bulkSelectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        let editSelectedButton = app.buttons["editSelectedMediaButton"]
        XCTAssertTrue(editSelectedButton.waitForExistence(timeout: 2))
        XCTAssertFalse(editSelectedButton.isEnabled)

        let rowOrder = [7, 10, 3, 4, 8, 1, 6, 9, 5, 2]
        let rows = rowOrder.map { app.descendants(matching: .any)["mediaRow.\($0)"] }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 2))
        }

        for (offset, row) in rows.enumerated() {
            row.click()
            let expectedCount = "\(offset + 1)"
            expectation(
                for: NSPredicate(format: "value == %@", expectedCount),
                evaluatedWith: status
            )
            waitForExpectations(timeout: 2)
        }
        XCTAssertTrue(editSelectedButton.isEnabled)

        expectation(
            for: NSPredicate(format: "value == %@", "\(rowOrder.count)"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 3)
        for row in rows {
            XCTAssertTrue(row.isSelected)
        }

        rows[3].click()
        expectation(
            for: NSPredicate(format: "value == %@", "\(rowOrder.count - 1)"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)
        XCTAssertFalse(rows[3].isSelected)
        for (index, row) in rows.enumerated() where index != 3 {
            XCTAssertTrue(row.isSelected)
        }

        rows[3].click()
        expectation(
            for: NSPredicate(format: "value == %@", "\(rowOrder.count)"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)
        XCTAssertTrue(rows[3].isSelected)

        let bulkSelectionCancelButton = app.buttons["bulkSelectionCancelButton"]
        XCTAssertTrue(bulkSelectionCancelButton.waitForExistence(timeout: 2))
        bulkSelectionCancelButton.click()
        XCTAssertFalse(status.waitForExistence(timeout: 1))
        for row in rows {
            XCTAssertFalse(row.isSelected)
        }

        XCTAssertTrue(multipleEditButton.waitForExistence(timeout: 2))
        multipleEditButton.click()
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(status.waitForExistence(timeout: 1))
    }

    @MainActor
    func testColumnBoundariesCannotBypassBulkSelection() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()

        let multipleEditButton = app.buttons["multipleEditButton"]
        if !multipleEditButton.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(multipleEditButton.waitForExistence(timeout: 5))
        multipleEditButton.click()

        let status = app.descendants(matching: .any)["bulkSelectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))

        let rows = (1...3).map { app.descendants(matching: .any)["mediaRow.\($0)"] }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 2))
        }

        let localizedHeaderTitles = [
            ("アーティスト", "Artist"),
            ("アルバム", "Album"),
            ("ジャンル", "Genre")
        ]
        let headers = localizedHeaderTitles.map { japaneseTitle, englishTitle in
            let japaneseHeader = app.buttons[japaneseTitle]
            return japaneseHeader.exists ? japaneseHeader : app.buttons[englishTitle]
        }
        for header in headers {
            XCTAssertTrue(header.waitForExistence(timeout: 2))
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2))

        for (offset, pair) in zip(rows, headers).enumerated() {
            let (row, header) = pair
            let boundaryCoordinate = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(
                    CGVector(
                        dx: header.frame.minX - window.frame.minX,
                        dy: row.frame.midY - window.frame.minY
                    )
                )
            boundaryCoordinate.click()

            let expectedCount = "\(offset + 1)"
            expectation(
                for: NSPredicate(format: "value == %@", expectedCount),
                evaluatedWith: status
            )
            waitForExpectations(timeout: 2)
        }

        for row in rows {
            XCTAssertTrue(row.isSelected)
        }
    }

    @MainActor
    func testClickSelectedRowCanBeDeselectedByClickingItAgain() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()

        let multipleEditButton = app.buttons["multipleEditButton"]
        if !multipleEditButton.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(multipleEditButton.waitForExistence(timeout: 5))
        multipleEditButton.click()

        let status = app.descendants(matching: .any)["bulkSelectionStatus"]
        let rows = (1...3).map { app.descendants(matching: .any)["mediaRow.\($0)"] }
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 2))
        }

        for (offset, row) in rows.enumerated() {
            row.click()
            expectation(
                for: NSPredicate(format: "value == %@", "\(offset + 1)"),
                evaluatedWith: status
            )
            waitForExpectations(timeout: 2)
        }
        for row in rows {
            XCTAssertTrue(row.isSelected)
        }

        rows[1].click()
        expectation(
            for: NSPredicate(format: "value == %@", "2"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)
        XCTAssertTrue(rows[0].isSelected)
        XCTAssertFalse(rows[1].isSelected)
        XCTAssertTrue(rows[2].isSelected)

        for (expectedCount, row) in zip([1, 0], [rows[0], rows[2]]) {
            row.click()
            expectation(
                for: NSPredicate(format: "value == %@", "\(expectedCount)"),
                evaluatedWith: status
            )
            waitForExpectations(timeout: 2)
        }
        for row in rows {
            XCTAssertFalse(row.isSelected)
        }
    }

    @MainActor
    func testDragSelectedRowCanBeDeselectedByClickingIt() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()

        let multipleEditButton = app.buttons["multipleEditButton"]
        if !multipleEditButton.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(multipleEditButton.waitForExistence(timeout: 5))
        multipleEditButton.click()

        let status = app.descendants(matching: .any)["bulkSelectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))

        let rows = (1...5).map { app.descendants(matching: .any)["mediaRow.\($0)"] }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 2))
        }

        let dragStart = rows[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = rows[4].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.click(forDuration: 0.2, thenDragTo: dragEnd)

        expectation(
            for: NSPredicate(format: "value == %@", "5"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)
        for row in rows {
            XCTAssertTrue(row.isSelected)
        }

        rows[2].click()
        expectation(
            for: NSPredicate(format: "value == %@", "4"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)
        XCTAssertFalse(rows[2].isSelected)
        for (index, row) in rows.enumerated() where index != 2 {
            XCTAssertTrue(row.isSelected)
        }

        let remainingRows = [rows[0], rows[1], rows[3], rows[4]]
        for (expectedCount, row) in zip([3, 2, 1, 0], remainingRows) {
            row.click()
            expectation(
                for: NSPredicate(format: "value == %@", "\(expectedCount)"),
                evaluatedWith: status
            )
            waitForExpectations(timeout: 2)
        }
        for row in rows {
            XCTAssertFalse(row.isSelected)
        }
    }

    @MainActor
    func testSmallPointerMovementStillDeselectsDragSelectedRow() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()

        let multipleEditButton = app.buttons["multipleEditButton"]
        if !multipleEditButton.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(multipleEditButton.waitForExistence(timeout: 5))
        multipleEditButton.click()

        let status = app.descendants(matching: .any)["bulkSelectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))

        let rows = (1...5).map { app.descendants(matching: .any)["mediaRow.\($0)"] }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 2))
        }

        let dragStart = rows[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = rows[4].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.click(forDuration: 0.2, thenDragTo: dragEnd)

        expectation(
            for: NSPredicate(format: "value == %@", "5"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)

        let selectedRow = rows[2]
        let clickStart = selectedRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let clickWithPointerJitter = clickStart.withOffset(CGVector(dx: 2, dy: 1))
        clickStart.click(forDuration: 0.1, thenDragTo: clickWithPointerJitter)

        expectation(
            for: NSPredicate(format: "value == %@", "4"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)
        XCTAssertFalse(selectedRow.isSelected)
        for (index, row) in rows.enumerated() where index != 2 {
            XCTAssertTrue(row.isSelected)
        }
    }

    @MainActor
    func testDraggingAcrossRowsSelectsTheEntireRangeForEditing() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()

        let multipleEditButton = app.buttons["multipleEditButton"]
        if !multipleEditButton.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(multipleEditButton.waitForExistence(timeout: 5))
        multipleEditButton.click()

        let status = app.descendants(matching: .any)["bulkSelectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))

        let rows = (1...6).map { app.descendants(matching: .any)["mediaRow.\($0)"] }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 2))
        }

        let dragStart = rows[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = rows[4].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.click(forDuration: 0.2, thenDragTo: dragEnd)

        expectation(
            for: NSPredicate(format: "value == %@", "5"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)
        for row in rows[0...4] {
            XCTAssertTrue(row.isSelected)
        }

        rows[5].click()
        expectation(
            for: NSPredicate(format: "value == %@", "6"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 2)
        for row in rows {
            XCTAssertTrue(row.isSelected)
        }

        let editSelectedButton = app.buttons["editSelectedMediaButton"]
        XCTAssertTrue(editSelectedButton.waitForExistence(timeout: 2))
        XCTAssertEqual(editSelectedButton.value as? String, "6")
        editSelectedButton.click()

        let editSelectionSummary = app.staticTexts["bulkEditSelectionSummary"]
        XCTAssertTrue(editSelectionSummary.waitForExistence(timeout: 2))
        XCTAssertEqual(editSelectionSummary.value as? String, "6")
    }

    @MainActor
    func testMainPlayerScreenExposesEveryAppOwnedButton() throws {
        let app = launchMainScreenTestApp()

        let alwaysEnabledButtonIdentifiers = [
            "addPlaylistButton",
            "importMediaButton",
            "exportToFinderButton",
            "multipleEditButton",
            "lyricsButton",
            "equalizerButton",
            "settingsButton",
            "advancedSearchButton",
            "pitchButton",
            "speedButton",
            "volumeUpButton",
            "volumeDownButton"
        ]
        for identifier in alwaysEnabledButtonIdentifiers {
            assertButton(identifier, isEnabled: true, in: app)
        }

        let playbackButtonIdentifiers = [
            "previousTrackButton",
            "playButton",
            "pauseButton",
            "stopButton",
            "nextTrackButton",
            "saveAdjustedCopyButton"
        ]
        for identifier in playbackButtonIdentifiers {
            assertButton(identifier, in: app)
        }

        let localizedColumnHeaders = [
            (english: "No.", japanese: "番号"),
            (english: "Title", japanese: "タイトル"),
            (english: "Artist", japanese: "アーティスト"),
            (english: "Album", japanese: "アルバム"),
            (english: "Genre", japanese: "ジャンル"),
            (english: "Time", japanese: "時間")
        ]
        for header in localizedColumnHeaders {
            let button = localizedButton(
                named: header.english,
                japaneseName: header.japanese,
                in: app
            )
            XCTAssertTrue(button.waitForExistence(timeout: 2), "Missing sortable column button: \(header.english)")
            XCTAssertTrue(button.isEnabled, "Expected sortable column button to be enabled: \(header.english)")
        }

        let middleRow = app.descendants(matching: .any)["mediaRow.5"]
        XCTAssertTrue(middleRow.waitForExistence(timeout: 2))
        middleRow.click()

        for identifier in ["previousTrackButton", "playButton", "nextTrackButton"] {
            waitForEnabledState(true, of: app.buttons[identifier])
        }
        for identifier in ["pauseButton", "stopButton", "saveAdjustedCopyButton"] {
            XCTAssertFalse(
                app.buttons[identifier].isEnabled, "Expected \(identifier) to remain disabled before playback"
            )
        }
    }

    @MainActor
    func testMainToolbarButtonsPresentAndDismissTheirSurfaces() throws {
        let app = launchMainScreenTestApp()

        let lyricsButton = app.buttons["lyricsButton"]
        let originalLyricsState = try XCTUnwrap(lyricsButton.value as? String)
        lyricsButton.click()
        waitForValueDifferent(from: originalLyricsState, of: lyricsButton)
        lyricsButton.click()
        waitForValue(originalLyricsState, of: lyricsButton)

        let flattenButton = app.buttons["flattenEqualizerButton"]
        let equalizerWasVisible = flattenButton.exists
        let equalizerButton = app.buttons["equalizerButton"]
        let originalEqualizerState = try XCTUnwrap(equalizerButton.value as? String)
        equalizerButton.click()
        waitForValueDifferent(from: originalEqualizerState, of: equalizerButton)
        if equalizerWasVisible {
            XCTAssertFalse(flattenButton.waitForExistence(timeout: 1))
        } else {
            assertButton("flattenEqualizerButton", in: app)
        }
        equalizerButton.click()
        waitForValue(originalEqualizerState, of: equalizerButton)
        XCTAssertEqual(flattenButton.exists, equalizerWasVisible)

        let advancedSearchButton = app.buttons["advancedSearchButton"]
        let originalAdvancedSearchState = try XCTUnwrap(advancedSearchButton.value as? String)
        advancedSearchButton.click()
        waitForValueDifferent(from: originalAdvancedSearchState, of: advancedSearchButton)
        app.typeKey(.escape, modifierFlags: [])
        waitForValue(originalAdvancedSearchState, of: advancedSearchButton)

        let settingsButton = app.buttons["settingsButton"]
        let originalSettingsState = try XCTUnwrap(settingsButton.value as? String)
        settingsButton.click()
        waitForValueDifferent(from: originalSettingsState, of: settingsButton)
        assertButton("settingsCloseButton", isEnabled: true, in: app)
        app.buttons["settingsCloseButton"].click()
        waitForValue(originalSettingsState, of: settingsButton)
        XCTAssertFalse(app.buttons["settingsCloseButton"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testPitchSpeedAndVolumeButtonsRespond() throws {
        let app = launchMainScreenTestApp()

        app.buttons["pitchButton"].click()
        assertButton("pitchDownButton", isEnabled: true, in: app)
        assertButton("pitchUpButton", isEnabled: true, in: app)
        assertButton("pitchResetButton", isEnabled: false, in: app)
        app.buttons["pitchUpButton"].click()
        waitForEnabledState(true, of: app.buttons["pitchResetButton"])
        app.buttons["pitchResetButton"].click()
        waitForEnabledState(false, of: app.buttons["pitchResetButton"])
        app.buttons["pitchButton"].click()
        XCTAssertFalse(app.buttons["pitchUpButton"].waitForExistence(timeout: 1))

        app.buttons["speedButton"].click()
        assertButton("slowerButton", isEnabled: true, in: app)
        assertButton("fasterButton", isEnabled: true, in: app)
        assertButton("speedResetButton", isEnabled: false, in: app)
        app.buttons["fasterButton"].click()
        waitForEnabledState(true, of: app.buttons["speedResetButton"])
        app.buttons["speedResetButton"].click()
        waitForEnabledState(false, of: app.buttons["speedResetButton"])
        app.buttons["speedButton"].click()
        XCTAssertFalse(app.buttons["fasterButton"].waitForExistence(timeout: 1))

        let volumeDownButton = app.buttons["volumeDownButton"]
        let originalVolume = try XCTUnwrap(volumeDownButton.value as? String)
        volumeDownButton.click()
        waitForValueDifferent(from: originalVolume, of: volumeDownButton)
        app.buttons["volumeUpButton"].click()
        waitForValue(originalVolume, of: volumeDownButton)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    private func localizedPlaylist(
        named englishName: String, japaneseName: String, in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier IN %@ OR label IN %@ OR value IN %@",
                [englishName, japaneseName],
                [englishName, japaneseName],
                [englishName, japaneseName]
            ))
            .firstMatch
    }

    @MainActor
    private func launchMainScreenTestApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-multiple-selection",
            "-ApplePersistenceIgnoreState", "YES",
            "-bottomPanelLayout", "classic"
        ]
        app.launch()
        app.activate()
        let mainWindowAnchor = app.buttons["addPlaylistButton"]
        if !mainWindowAnchor.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(mainWindowAnchor.waitForExistence(timeout: 5), "The main player window did not open")
        return app
    }

    @MainActor
    private func assertButton(
        _ identifier: String,
        isEnabled expectedEnabled: Bool? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = app.buttons[identifier]
        let exists = button.exists || button.waitForExistence(timeout: 3)
        XCTAssertTrue(
            exists,
            "Missing button with identifier \(identifier)",
            file: file,
            line: line
        )
        if let expectedEnabled {
            XCTAssertEqual(
                button.isEnabled,
                expectedEnabled,
                "Unexpected enabled state for \(identifier)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func localizedButton(
        named englishName: String, japaneseName: String, in app: XCUIApplication
    ) -> XCUIElement {
        let englishButton = app.buttons[englishName]
        return englishButton.exists ? englishButton : app.buttons[japaneseName]
    }

    @MainActor
    private func waitForEnabledState(
        _ enabled: Bool,
        of element: XCUIElement,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "enabled == %@", NSNumber(value: enabled))
        let stateExpectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [stateExpectation], timeout: timeout),
            .completed,
            "Element did not become \(enabled ? "enabled" : "disabled")",
            file: file,
            line: line
        )
    }

    @MainActor
    private func waitForValue(
        _ value: String,
        of element: XCUIElement,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "value == %@", value)
        let valueExpectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [valueExpectation], timeout: timeout),
            .completed,
            "Element did not reach expected value \(value)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func waitForValueDifferent(
        from value: String,
        of element: XCUIElement,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "value != %@", value)
        let valueExpectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [valueExpectation], timeout: timeout),
            .completed,
            "Element value did not change from \(value)",
            file: file,
            line: line
        )
    }
    #endif
}

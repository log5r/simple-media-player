import AVFoundation
import Foundation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#endif
@testable import SimpleMediaPlayer

struct EqualizerSettingsTests {
    @Test func saveAndLoadRoundTrip() throws {
        let suiteName = "EqualizerSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = EqualizerSettings(
            isEnabled: true,
            preampDecibels: 3.5,
            bandGains: [-12, -9, -6, -3, 0, 3, 6, 9, 11, 12],
            reverbPreset: .largeHall,
            reverbWetDryMix: 28
        )

        settings.save(to: defaults)

        #expect(EqualizerSettings.load(from: defaults) == settings)
    }

    @Test func invalidDataAndBandCountsFallBackToFlat() throws {
        let suiteName = "EqualizerSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not-json".utf8), forKey: AppSettingsKey.equalizerSettings)
        #expect(EqualizerSettings.load(from: defaults) == .flat)

        let invalidBandCount = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "preampDecibels": 2,
            "bandGains": [1, 2, 3]
        ])
        defaults.set(invalidBandCount, forKey: AppSettingsKey.equalizerSettings)
        #expect(EqualizerSettings.load(from: defaults) == .flat)
    }

    @Test func legacyFrequencyLayoutIsMigratedOnLoad() throws {
        let suiteName = "EqualizerSettingsLegacyMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyBandGains: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "preampDecibels": -3,
            "bandGains": legacyBandGains
        ])
        defaults.set(legacyData, forKey: AppSettingsKey.equalizerSettings)

        let migrated = EqualizerSettings.load(from: defaults)

        #expect(migrated.isEnabled)
        #expect(migrated.preampDecibels == -3)
        #expect(migrated.bandGains[0] == legacyBandGains[0])
        #expect(migrated.bandGains[5] == legacyBandGains[4])
        #expect(migrated.bandGains[9] == legacyBandGains[9])
        #expect(migrated.bandGains[1] > legacyBandGains[0])
        #expect(migrated.bandGains[1] < legacyBandGains[1])
        #expect(migrated.reverbPreset == .mediumRoom)
        #expect(migrated.reverbWetDryMix == 0)
    }

    @Test func gainsAreClampedOnInitialization() {
        let settings = EqualizerSettings(
            isEnabled: true,
            preampDecibels: 99,
            bandGains: Array(repeating: -99, count: EqualizerSettings.bandCount),
            reverbWetDryMix: 150
        )

        #expect(settings.preampDecibels == 12)
        #expect(settings.bandGains.allSatisfy { $0 == -12 })
        #expect(settings.reverbWetDryMix == 100)
    }

    @Test func flatCurveIsZeroAndSingleBandPeaksNearItsCenterFrequency() throws {
        let flatCurve = EqualizerSettings.responseCurve(
            preamp: 0,
            bandGains: Array(repeating: 0, count: EqualizerSettings.bandCount),
            sampleCount: 121
        )
        #expect(flatCurve.allSatisfy { abs($0.y) < 0.000_001 })

        var gains = Array(repeating: Float(0), count: EqualizerSettings.bandCount)
        gains[5] = 12
        let curve = EqualizerSettings.responseCurve(preamp: 0, bandGains: gains, sampleCount: 301)
        let peak = try #require(curve.max(by: { $0.y < $1.y }))
        let expectedX = log(1_000.0 / 20.0) / log(20_000.0 / 20.0)

        #expect(peak.y > 11.9)
        #expect(abs(peak.x - expectedX) < 0.01)
    }

    @Test func bandwidthsFollowTheWidestAdjacentFrequencySpacing() {
        #expect(EqualizerSettings.bandFrequencies == [
            31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
        ])
        #expect(EqualizerSettings.bandBandwidths.count == EqualizerSettings.bandCount)
        #expect(EqualizerSettings.bandBandwidths.allSatisfy { $0 > 0.98 && $0 < 1.02 })
    }

    @Test func matchingLowBandsFormAContinuousBoost() {
        var gains = Array(repeating: Float(0), count: EqualizerSettings.bandCount)
        gains[0] = 8.6
        gains[1] = 8.6
        let lowFrequency = EqualizerSettings.bandFrequencies[0]
        let highFrequency = EqualizerSettings.bandFrequencies[1]
        let midpointFrequency = sqrt(lowFrequency * highFrequency)
        let lowCenter = EqualizerSettings.responseDecibels(at: lowFrequency, preamp: 0, bandGains: gains)
        let midpoint = EqualizerSettings.responseDecibels(at: midpointFrequency, preamp: 0, bandGains: gains)
        let highCenter = EqualizerSettings.responseDecibels(at: highFrequency, preamp: 0, bandGains: gains)

        #expect(lowCenter - midpoint < 2)
        #expect(highCenter - midpoint < 2)
        #expect(midpoint > 8.5)
    }
}

struct VideoEqualizerProcessorTests {
    @Test func disabledEqualizerLeavesSamplesUnchanged() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        let samples = try #require(buffer.floatChannelData?[0])
        let input: [Float] = [-0.8, -0.4, -0.1, 0, 0.1, 0.3, 0.6, 0.9]
        buffer.frameLength = AVAudioFrameCount(input.count)
        for (index, value) in input.enumerated() {
            samples[index] = value
        }

        let processor = VideoEqualizerProcessor()
        processor.prepare(format: format)
        processor.process(buffer)

        #expect((0..<input.count).map { samples[$0] } == input)
    }

    @Test func updatedBandGainBoostsItsCenterFrequency() throws {
        let sampleRate = 48_000.0
        let frameCount = 8_192
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        )
        let samples = try #require(buffer.floatChannelData?[0])
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            samples[frame] = 0.1 * sin(Float(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
        }

        var bandGains = Array(repeating: Float(0), count: EqualizerSettings.bandCount)
        bandGains[5] = 12
        let processor = VideoEqualizerProcessor()
        processor.prepare(format: format)
        processor.setSettings(EqualizerSettings(
            isEnabled: true,
            preampDecibels: 0,
            bandGains: bandGains
        ))
        processor.process(buffer)

        let settledSamples = (frameCount / 2..<frameCount).map { Double(samples[$0]) }
        let outputRMS = sqrt(settledSamples.reduce(0) { $0 + $1 * $1 } / Double(settledSamples.count))
        let inputRMS = 0.1 / sqrt(2)
        #expect(outputRMS / inputRMS > 3.8)
        #expect(outputRMS / inputRMS < 4.15)
    }
}

struct EqualizerPresetTests {
    @Test func builtInPresetsHaveValidDistinctSettings() {
        let presets = BuiltInEqualizerPreset.allCases

        #expect(BuiltInEqualizerPreset.studio.settings != BuiltInEqualizerPreset.concertHall.settings)
        #expect(BuiltInEqualizerPreset.concertHall.settings != BuiltInEqualizerPreset.outdoorStage.settings)
        #expect(presets.allSatisfy { $0.settings.isEnabled })
        #expect(presets.allSatisfy { $0.settings.bandGains.count == EqualizerSettings.bandCount })
        #expect(BuiltInEqualizerPreset.concertHall.settings.reverbWetDryMix
            > BuiltInEqualizerPreset.outdoorStage.settings.reverbWetDryMix)
    }

    @Test func userPresetsPersistAndInvalidDataFallsBackToEmpty() throws {
        let suiteName = "UserEqualizerPresetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let presets = [
            UserEqualizerPreset(name: "Favorite", settings: BuiltInEqualizerPreset.studio.settings),
            UserEqualizerPreset(name: "Live", settings: BuiltInEqualizerPreset.concertHall.settings)
        ]

        UserEqualizerPreset.save(presets, to: defaults)
        #expect(UserEqualizerPreset.load(from: defaults) == presets)

        defaults.set(Data("invalid".utf8), forKey: AppSettingsKey.equalizerUserPresets)
        #expect(UserEqualizerPreset.load(from: defaults).isEmpty)
    }
}

@MainActor
struct BottomPanelSettingsTests {
    @Test func defaultsUseLEDHalfLayoutAndRecommendedHalfPanelOptions() {
        #expect(BottomPanelLayout(rawValue: AppSettingsDefault.bottomPanelLayout) == .ledHalf)
        #expect(LEDPanelSide(rawValue: AppSettingsDefault.ledPanelSide) == .right)
        #expect(LEDPanelCorner(rawValue: AppSettingsDefault.ledPanelCorner) == .adaptive)
        #expect(LEDDisplayStyle(rawValue: AppSettingsDefault.ledDisplayStyle) == .dark)
        #expect(AppSettingsDefault.ledBacklitForegroundColorHex == "#000000")
        #expect(AppSettingsDefault.ledBacklightColorHex == "#E5E89D")
        #expect(AppSettingsKey.ledBacklitGlassIntensity == "ledBacklitGlassIntensity")
        #expect(AppSettingsDefault.ledBacklitGlassIntensity == 0.18)
        #expect(AppSettingsDefault.ledBacklitGlassIntensityRange == 0...0.5)
        #expect(AppSettingsDefault.ledBacklitGlassIntensityStep == 0.02)
        #expect(
            AppSettingsDefault.ledBacklitGlassIntensityRange.contains(
                AppSettingsDefault.ledBacklitGlassIntensity
            )
        )
    }

    @Test func legacyLEDColorStorageRemainsTheDarkForeground() {
        #expect(AppSettingsKey.ledColorHex == "ledColorHex")
        #expect(AppSettingsDefault.ledColorHex == "#FFFFFF")
        #expect(AppSettingsKey.ledBacklitForegroundColorHex == "ledBacklitForegroundColorHex")
        #expect(AppSettingsKey.ledBacklightColorHex == "ledBacklightColorHex")
    }

    @Test func invalidRawValuesFallBackToDocumentedOptions() {
        #expect((BottomPanelLayout(rawValue: "invalid") ?? .classic) == .classic)
        #expect((LEDPanelSide(rawValue: "invalid") ?? .right) == .right)
        #expect((LEDPanelCorner(rawValue: "invalid") ?? .adaptive) == .adaptive)
        #expect((LEDDisplayStyle(rawValue: "invalid") ?? .dark) == .dark)
    }

    @Test func ledDisplayStylesOfferDarkAndBacklitPatterns() {
        #expect(LEDDisplayStyle.allCases == [.dark, .backlit])
    }

    @Test func adaptiveCornerTracksTheOuterBottomEdge() {
        let leftStyles = LEDPanelCorner.adaptive.cornerStyles(side: .left)
        #expect(leftStyles.bottomLeading == .concentric(minimum: .fixed(10)))
        #expect(leftStyles.bottomTrailing == .fixed(2))

        let rightStyles = LEDPanelCorner.adaptive.cornerStyles(side: .right)
        #expect(rightStyles.bottomLeading == .fixed(2))
        #expect(rightStyles.bottomTrailing == .concentric(minimum: .fixed(10)))
    }

    @Test func bezelInsetKeepsTheInnerCornerConcentric() {
        let outerStyles = LEDPanelCorner.adaptive.cornerStyles(side: .left)
        let innerStyles = LEDPanelCorner.adaptive.cornerStyles(side: .left, inset: 1)

        #expect(outerStyles.bottomLeading == .concentric(minimum: .fixed(10)))
        #expect(innerStyles.bottomLeading == .concentric(minimum: .fixed(9)))
        #expect(innerStyles.bottomTrailing == .fixed(1))
    }
}

struct BulkMediaSelectionTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func consecutivePlainClicksKeepPreviouslySelectedRows() {
        let firstSelection = BulkMediaSelection.toggling(firstID, in: [])
        let secondSelection = BulkMediaSelection.toggling(secondID, in: firstSelection)

        #expect(secondSelection == [firstID, secondID])
    }

    @Test func plainClickRemovesAnAlreadySelectedRow() {
        let updated = BulkMediaSelection.toggling(secondID, in: [firstID, secondID])

        #expect(updated == [firstID])
    }

    @Test func everyClickInARapidSequenceIsAppliedExactlyOnce() {
        let updated = [firstID, secondID, thirdID, secondID].reduce(into: Set<UUID>()) { selection, id in
            selection = BulkMediaSelection.toggling(id, in: selection)
        }

        #expect(updated == [firstID, thirdID])
    }
}

@MainActor
struct BulkMediaSelectionStateTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func callbacksCreatedBeforeSelectionChangesAlwaysMutateLatestState() {
        let selection = BulkMediaSelectionState()
        let toggleFirst = { selection.toggle(firstID) }
        let toggleSecond = { selection.toggle(secondID) }
        let toggleThird = { selection.toggle(thirdID) }

        toggleFirst()
        toggleSecond()
        toggleThird()
        toggleSecond()

        #expect(selection.ids == [firstID, thirdID])
    }

    @Test func retainAndResetMutateTheSharedState() {
        let selection = BulkMediaSelectionState(ids: [firstID, secondID, thirdID])

        selection.retain(ids: [firstID, thirdID])
        #expect(selection.ids == [firstID, thirdID])

        selection.reset()
        #expect(selection.ids.isEmpty)
    }

    @Test func dragPreviewReplacesThePreviousRangeWithoutTouchingTheSelection() {
        let selection = BulkMediaSelectionState(ids: [firstID])

        selection.updateDragPreview([firstID, secondID])
        #expect(selection.dragPreviewIDs == [firstID, secondID])
        #expect(selection.isDragPreviewed(secondID))

        selection.updateDragPreview([thirdID])
        #expect(selection.dragPreviewIDs == [thirdID])
        #expect(selection.isDragPreviewed(secondID) == false)
        #expect(selection.ids == [firstID])
    }

    @Test func clearingAndResettingRemoveTheDragPreview() {
        let selection = BulkMediaSelectionState()

        selection.updateDragPreview([firstID, secondID])
        selection.clearDragPreview()
        #expect(selection.dragPreviewIDs.isEmpty)

        selection.updateDragPreview([thirdID])
        selection.reset()
        #expect(selection.dragPreviewIDs.isEmpty)
    }
}

#if os(macOS)
@MainActor
struct TableRowSelectionBackgroundTests {
    @Test func alternatingBackgroundUsesTheColorMatchingTheRowIndex() {
        let colors: [NSColor] = [.red, .blue]

        #expect(AlternatingTableRowBackground.color(rowIndex: 0, colors: colors) == .red)
        #expect(AlternatingTableRowBackground.color(rowIndex: 1, colors: colors) == .blue)
        #expect(AlternatingTableRowBackground.color(rowIndex: 2, colors: colors) == .red)
    }

    @Test func alternatingBackgroundFallsBackToClearWithoutAUsableRow() {
        #expect(AlternatingTableRowBackground.color(rowIndex: -1, colors: [.red]) == .clear)
        #expect(AlternatingTableRowBackground.color(rowIndex: 0, colors: []) == .clear)
    }

    @Test func detachingOneCellDoesNotClearAnotherCellsSelectedRowBackground() {
        let rowView = NSTableRowView()
        let firstCellBackground = TableRowSelectionBackgroundView(isSelected: true)
        let secondCellBackground = TableRowSelectionBackgroundView(isSelected: true)
        rowView.addSubview(firstCellBackground)
        rowView.addSubview(secondCellBackground)

        firstCellBackground.detachFromRow()
        #expect(rowView.backgroundColor == .selectedContentBackgroundColor)

        secondCellBackground.detachFromRow()
        #expect(rowView.backgroundColor == .clear)
    }

    @Test func dragPreviewTintsTheRowUntilSelectionOrDetachmentWins() {
        let rowView = NSTableRowView()
        let cellBackground = TableRowSelectionBackgroundView(isSelected: false, isDragPreviewed: true)
        rowView.addSubview(cellBackground)

        cellBackground.isDragPreviewed = true
        #expect(rowView.backgroundColor == TableRowSelectionBackgroundView.dragPreviewRowBackgroundColor)

        cellBackground.isSelected = true
        #expect(rowView.backgroundColor == .selectedContentBackgroundColor)

        cellBackground.detachFromRow()
        #expect(rowView.backgroundColor == .clear)
    }
}

@MainActor
struct TableBulkSelectionInputViewTests {
    @Test func rapidClicksImmediatelyApplyEveryRowSelection() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let selection = BulkMediaSelectionState()
        let inputView = TableBulkSelectionInputView(
            isEnabled: true,
            selection: selection,
            rowIDs: [firstID, secondID]
        )

        #expect(inputView.toggleRow(at: 0))
        #expect(inputView.toggleRow(at: 1))
        #expect(selection.ids == [firstID, secondID])

        #expect(inputView.toggleRow(at: 0))
        #expect(selection.ids == [secondID])
    }

    @Test func disabledInputAndInvalidRowsDoNotChangeSelection() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let selection = BulkMediaSelectionState()
        let inputView = TableBulkSelectionInputView(
            isEnabled: false,
            selection: selection,
            rowIDs: [id]
        )

        #expect(inputView.toggleRow(at: 0) == false)
        inputView.isEnabled = true
        #expect(inputView.toggleRow(at: -1) == false)
        #expect(inputView.toggleRow(at: 1) == false)
        #expect(selection.ids.isEmpty)
    }

    @Test func draggingSelectsEveryRowBetweenTheAnchorAndCurrentRow() {
        let ids = (1...6).map { _ in UUID() }
        let selection = BulkMediaSelectionState()
        let inputView = TableBulkSelectionInputView(
            isEnabled: true,
            selection: selection,
            rowIDs: ids
        )

        #expect(inputView.selectRows(from: 0, through: 4))
        #expect(selection.ids == Set(ids[0...4]))

        #expect(inputView.selectRows(from: -1, through: 5) == false)
    }

    @Test func reverseDraggingSelectsTheWholeRangeWithoutRemovingExistingRows() {
        let ids = (1...7).map { _ in UUID() }
        let selection = BulkMediaSelectionState(ids: [ids[6]])
        let inputView = TableBulkSelectionInputView(
            isEnabled: true,
            selection: selection,
            rowIDs: ids
        )

        #expect(inputView.selectRows(from: 4, through: 1))
        #expect(selection.ids == Set(ids[1...4]).union([ids[6]]))
    }

    @Test func previewingRowsTracksTheDraggedRangeWithoutSelectingThem() {
        let ids = (1...6).map { _ in UUID() }
        let selection = BulkMediaSelectionState()
        let inputView = TableBulkSelectionInputView(
            isEnabled: true,
            selection: selection,
            rowIDs: ids
        )

        #expect(inputView.previewRows(from: 1, through: 4))
        #expect(selection.dragPreviewIDs == Set(ids[1...4]))
        #expect(selection.ids.isEmpty)

        #expect(inputView.previewRows(from: 4, through: 2))
        #expect(selection.dragPreviewIDs == Set(ids[2...4]))

        #expect(inputView.previewRows(from: -1, through: 5) == false)

        inputView.isEnabled = false
        #expect(inputView.previewRows(from: 0, through: 1) == false)
    }
}
#endif

@MainActor
struct LyricsParserTests {
    @Test func parseNilAndWhitespaceAsEmptyLyrics() {
        let nilResult = LyricsParser.parse(nil)
        #expect(nilResult.lines.isEmpty)
        #expect(nilResult.hasTimeTags == false)

        let whitespaceResult = LyricsParser.parse(" \n\t ")
        #expect(whitespaceResult.lines.isEmpty)
        #expect(whitespaceResult.hasTimeTags == false)
    }

    @Test func parsePlainLyricsPreservesTextAndBlankLines() {
        let result = LyricsParser.parse(" first line \n\nsecond line")

        #expect(result.hasTimeTags == false)
        #expect(result.lines.count == 3)
        #expect(result.lines[0].text == "first line")
        #expect(result.lines[0].timestamp == nil)
        #expect(result.lines[1].text == "")
        #expect(result.lines[1].timestamp == nil)
        #expect(result.lines[2].text == "second line")
        #expect(result.lines[2].timestamp == nil)
    }

    @Test func parseTimedLyricsFiltersMetadataAndSortsByTimestamp() {
        let raw = """
        [ti:Title]
        [00:12.50]second
        [00:01.25]first
        [ar:Artist]
        plain tail
        """

        let result = LyricsParser.parse(raw)

        #expect(result.hasTimeTags)
        #expect(result.lines.map(\.text) == ["first", "second", "plain tail"])
        #expect(result.lines[0].timestamp == 1.25)
        #expect(result.lines[1].timestamp == 12.5)
        #expect(result.lines[2].timestamp == nil)
    }

    @Test func parseMultipleTimestampsCreatesOneLinePerTimestamp() {
        let result = LyricsParser.parse("[00:03.00][00:04.50]repeat")

        #expect(result.hasTimeTags)
        #expect(result.lines.map(\.text) == ["repeat", "repeat"])
        #expect(result.lines[0].timestamp == 3)
        #expect(result.lines[1].timestamp == 4.5)
    }

    @Test func parseMalformedTimedLineAsPlainText() {
        let result = LyricsParser.parse("[00:bad]not timed")

        #expect(result.hasTimeTags == false)
        #expect(result.lines.count == 1)
        #expect(result.lines[0].text == "[00:bad]not timed")
        #expect(result.lines[0].timestamp == nil)
    }
}

@MainActor
struct MediaFormatInfoTests {
    @Test func ledRowsOmitsMissingAndNonPositiveValues() {
        let rows = MediaFormatInfo(
            sampleRateHz: 0,
            bitrateKbps: -1,
            videoFrameRateFps: nil,
            totalBitrateKbps: 320
        ).ledRows

        #expect(rows == [
            LEDInfoRow(id: "totalBitrate", value: "320", unit: "kbps")
        ])
    }

    @Test func ledRowsFormatsValuesInDisplayOrder() {
        let rows = MediaFormatInfo(
            sampleRateHz: 44_100,
            bitrateKbps: 256,
            videoFrameRateFps: 29.97,
            totalBitrateKbps: 1_500
        ).ledRows

        #expect(rows == [
            LEDInfoRow(id: "bitrate", value: "256", unit: "kbps"),
            LEDInfoRow(id: "sampleRate", value: "44.1", unit: "kHz"),
            LEDInfoRow(id: "frameRate", value: "30.0", unit: "fps"),
            LEDInfoRow(id: "totalBitrate", value: "1500", unit: "kbps")
        ])
    }

    @Test func ledRowsFormatsWholeKilohertzWithoutDecimalPlaces() {
        let rows = MediaFormatInfo(sampleRateHz: 48_000).ledRows

        #expect(rows == [
            LEDInfoRow(id: "sampleRate", value: "48", unit: "kHz")
        ])
    }
}

@MainActor
struct LEDColorValueTests {
    @Test func normalizedHexExpandsShortFormAndUppercasesLongForm() {
        #expect(LEDColorValue.normalizedHex("  #abc\n") == "#AABBCC")
        #expect(LEDColorValue.normalizedHex("00ff7a") == "#00FF7A")
    }

    @Test func normalizedHexRejectsInvalidInput() {
        #expect(LEDColorValue.normalizedHex("#12") == nil)
        #expect(LEDColorValue.normalizedHex("#12xz89") == nil)
    }

    @Test func resolvedParsesHexChannels() {
        let value = LEDColorValue.resolved("#336699")

        #expect(value.red == 0x33.toUnitColorChannel)
        #expect(value.green == 0x66.toUnitColorChannel)
        #expect(value.blue == 0x99.toUnitColorChannel)
    }

    @Test func resolvedUsesFallbackForInvalidHex() {
        #expect(LEDColorValue.resolved("invalid") == .fallback)
    }

    @Test func resolvedCanUseAColorRoleSpecificFallback() {
        let value = LEDColorValue.resolved(
            "invalid",
            fallbackHex: AppSettingsDefault.ledBacklightColorHex
        )

        #expect(value == LEDColorValue.resolved(AppSettingsDefault.ledBacklightColorHex))
    }
}

@MainActor
struct LEDDisplayPaletteTests {
    private let foreground = LEDColorValue.resolved("#336699")
    private let alternateForeground = LEDColorValue.resolved("#993366")
    private let backlight = LEDColorValue.resolved("#F2D39A")

    @Test func resolverPreservesLegacyDarkColorAndUsesIndependentBacklitColors() {
        let darkPalette = LEDDisplayPalette.resolved(
            styleRaw: "invalid",
            darkForegroundHex: "#336699",
            backlitForegroundHex: "#57351F",
            backlightHex: "#F2D39A"
        )
        let backlitPalette = LEDDisplayPalette.resolved(
            styleRaw: LEDDisplayStyle.backlit.rawValue,
            darkForegroundHex: "#336699",
            backlitForegroundHex: "#57351F",
            backlightHex: "#F2D39A",
            backlitGlassIntensity: 0.42
        )

        #expect(darkPalette.style == .dark)
        #expect(darkPalette.foreground == LEDColorValue.resolved("#336699"))
        #expect(darkPalette.primaryColor == LEDColorValue.resolved("#336699").color)
        #expect(backlitPalette.style == .backlit)
        #expect(backlitPalette.foreground == LEDColorValue.resolved("#57351F"))
        #expect(backlitPalette.backlight == LEDColorValue.resolved("#F2D39A"))
        #expect(backlitPalette.glassOverlayOpacity == 0.42)
    }

    @Test func darkPalettePreservesTheExistingLEDColors() {
        let palette = LEDDisplayPalette(
            foreground: foreground,
            backlight: backlight,
            style: .dark,
            backlitGlassIntensity: 0.42
        )
        let visualizerStyle = LEDStyle(palette: palette)

        #expect(palette.primaryColor == foreground.color)
        #expect(palette.backgroundColor == foreground.backgroundColor)
        #expect(palette.backgroundGlowColor == foreground.glowColor)
        #expect(visualizerStyle.onColor == foreground.color)
        #expect(visualizerStyle.peakColor == foreground.peakColor)
        #expect(visualizerStyle.offOpacity == 0.08)
        #expect(palette.glassOverlayOpacity == 1)
    }

    @Test func backlitPaletteKeepsForegroundAndBacklightIndependent() {
        let palette = LEDDisplayPalette(
            foreground: foreground,
            backlight: backlight,
            style: .backlit
        )
        let visualizerStyle = LEDStyle(palette: palette)
        let alternatePalette = LEDDisplayPalette(
            foreground: alternateForeground,
            backlight: backlight,
            style: .backlit
        )
        let alternateBacklight = LEDColorValue.resolved("#C9E3F2")
        let alternateBackgroundPalette = LEDDisplayPalette(
            foreground: foreground,
            backlight: alternateBacklight,
            style: .backlit
        )

        #expect(palette.primaryColor == foreground.color)
        #expect(palette.backgroundColor == backlight.color)
        #expect(palette.backgroundGlowColor == backlight.backlightGlowColor)
        #expect(visualizerStyle.onColor == foreground.color.opacity(0.78))
        #expect(visualizerStyle.peakColor == foreground.color.opacity(0.96))
        #expect(visualizerStyle.offOpacity == 0.12)
        #expect(palette.glassOverlayOpacity == 0.18)
        #expect(alternatePalette.primaryColor == alternateForeground.color)
        #expect(alternatePalette.backgroundColor == palette.backgroundColor)
        #expect(alternatePalette.backgroundGlowColor == palette.backgroundGlowColor)
        #expect(alternateBackgroundPalette.primaryColor == palette.primaryColor)
        #expect(alternateBackgroundPalette.visualizerOnColor == palette.visualizerOnColor)
        #expect(alternateBackgroundPalette.visualizerPeakColor == palette.visualizerPeakColor)
        #expect(alternateBackgroundPalette.backgroundColor == alternateBacklight.color)
        #expect(alternateBackgroundPalette.backgroundColor != palette.backgroundColor)
    }

    @Test func backlitGlassIntensityIsAdjustableAndBounded() {
        let custom = LEDDisplayPalette(
            foreground: foreground,
            backlight: backlight,
            style: .backlit,
            backlitGlassIntensity: 0.42
        )
        let belowRange = LEDDisplayPalette(
            foreground: foreground,
            backlight: backlight,
            style: .backlit,
            backlitGlassIntensity: -0.1
        )
        let aboveRange = LEDDisplayPalette(
            foreground: foreground,
            backlight: backlight,
            style: .backlit,
            backlitGlassIntensity: 0.8
        )
        let nonFinite = LEDDisplayPalette(
            foreground: foreground,
            backlight: backlight,
            style: .backlit,
            backlitGlassIntensity: .nan
        )

        #expect(custom.glassOverlayOpacity == 0.42)
        #expect(belowRange.glassOverlayOpacity == 0)
        #expect(aboveRange.glassOverlayOpacity == 0.5)
        #expect(nonFinite.glassOverlayOpacity == 0.18)
    }

    @Test func defaultBacklitPalettePreservesTheCurrentBlackOnYellowAppearance() {
        let defaultForeground = LEDColorValue.resolved(
            AppSettingsDefault.ledBacklitForegroundColorHex,
            fallbackHex: AppSettingsDefault.ledBacklitForegroundColorHex
        )
        let defaultBacklight = LEDColorValue.resolved(
            AppSettingsDefault.ledBacklightColorHex,
            fallbackHex: AppSettingsDefault.ledBacklightColorHex
        )
        let palette = LEDDisplayPalette(
            foreground: defaultForeground,
            backlight: defaultBacklight,
            style: .backlit
        )

        #expect(defaultForeground.red == 0)
        #expect(defaultForeground.green == 0)
        #expect(defaultForeground.blue == 0)
        #expect(palette.primaryColor == defaultForeground.color)
        #expect(palette.backgroundColor == defaultBacklight.color)
    }
}

@MainActor
struct MediaListColumnTests {
    @Test func defaultVisibleColumnsMatchCurrentSongListColumns() {
        #expect(MediaListColumn.defaultVisibleColumns == [
            .index,
            .artwork,
            .title,
            .artist,
            .album,
            .genre,
            .duration
        ])
    }

    @Test func defaultVisibilityFollowsDefaultVisibleColumns() {
        #expect(MediaListColumn.allCases.filter(\.isVisibleByDefault) == MediaListColumn.defaultVisibleColumns)
        #expect(MediaListColumn.title.defaultVisibility == .visible)
        #expect(MediaListColumn.fileName.defaultVisibility == .hidden)
    }

    @Test func columnStorageDecodesOrderWithMissingColumnsAppended() {
        let orderedColumns = MediaListColumn.orderedColumns(from: "album,title,title,unknown")

        #expect(orderedColumns.prefix(2) == [.album, .title])
        #expect(orderedColumns.count == MediaListColumn.allCases.count)
        #expect(Set(orderedColumns) == Set(MediaListColumn.allCases))
    }

    @Test func emptyVisibleColumnStorageFallsBackToDefaults() {
        #expect(MediaListColumn.visibleColumnSet(from: "") == Set(MediaListColumn.defaultVisibleColumns))
    }

    @Test func visibleColumnsFollowStoredOrderAndVisibility() {
        let visibleColumns = MediaListColumn.visibleColumns(
            orderRawValue: "album,title,artist",
            visibleRawValue: "title,artist"
        )

        #expect(visibleColumns == [.title, .artist])
    }
}

@MainActor
struct MediaItemTests {
    @Test func mediaItemInitializerStoresProvidedValues() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let addedAt = Date(timeIntervalSince1970: 123)
        let item = MediaItem(
            id: id,
            title: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Genre",
            duration: 12.5,
            isVideo: true,
            lyricsRaw: "lyrics",
            bookmarkData: Data([1, 2, 3]),
            artworkData: Data([4, 5]),
            addedAt: addedAt,
            fileName: "track.mov"
        )

        #expect(item.id == id)
        #expect(item.title == "Track")
        #expect(item.artist == "Artist")
        #expect(item.album == "Album")
        #expect(item.genre == "Genre")
        #expect(item.duration == 12.5)
        #expect(item.isVideo)
        #expect(item.lyricsRaw == "lyrics")
        #expect(item.bookmarkData == Data([1, 2, 3]))
        #expect(item.artworkData == Data([4, 5]))
        #expect(item.addedAt == addedAt)
        #expect(item.fileName == "track.mov")
    }

    @Test func playlistInitializersStoreProvidedValues() {
        let playlistID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let createdAt = Date(timeIntervalSince1970: 456)
        let entry = PlaylistEntry(id: entryID, sortIndex: 7)
        let playlist = Playlist(id: playlistID, name: "Favorites", createdAt: createdAt, entries: [entry])

        #expect(playlist.id == playlistID)
        #expect(playlist.name == "Favorites")
        #expect(playlist.createdAt == createdAt)
        #expect(playlist.entries.map(\.id) == [entryID])
        #expect(entry.sortIndex == 7)
    }

    @Test func metadataEditPatchAppliesOnlySelectedFields() {
        let original = MediaMetadataEditDraft(
            title: "Original Title",
            artist: "Original Artist",
            album: "Original Album",
            genre: "Original Genre",
            year: "2020",
            trackNumber: "1/10",
            comment: "Original Comment",
            albumArtist: "Original Album Artist",
            composer: "Original Composer",
            discNumber: "1/2",
            isCompilation: false
        )
        let draft = MediaMetadataEditDraft(
            title: "New Title",
            artist: "New Artist",
            album: "New Album",
            genre: "",
            year: "2026",
            trackNumber: "2/10",
            comment: "New Comment",
            albumArtist: "New Album Artist",
            composer: "New Composer",
            discNumber: "2/2",
            isCompilation: true
        )

        let patch = MediaMetadataEditPatch(fields: [.artist, .genre, .isCompilation], draft: draft)
        let patched = patch.applying(to: original)

        #expect(patched.title == "Original Title")
        #expect(patched.artist == "New Artist")
        #expect(patched.album == "Original Album")
        #expect(patched.genre == "")
        #expect(patched.year == "2020")
        #expect(patched.trackNumber == "1/10")
        #expect(patched.comment == "Original Comment")
        #expect(patched.albumArtist == "Original Album Artist")
        #expect(patched.composer == "Original Composer")
        #expect(patched.discNumber == "1/2")
        #expect(patched.isCompilation)
    }

    @Test func metadataEditPatchAppliesArtworkReplacementAndRemoval() {
        let oldArtwork = Data([1, 2])
        let newArtwork = Data([3, 4])
        let original = MediaMetadataEditDraft(
            title: "Title",
            artist: "Artist",
            album: "Album",
            genre: "Genre",
            artworkData: oldArtwork
        )
        let replacement = MediaMetadataEditDraft(
            title: "",
            artist: "",
            album: "",
            genre: "",
            artworkData: newArtwork
        )

        let replaced = MediaMetadataEditPatch(fields: [.artwork], draft: replacement).applying(to: original)
        #expect(replaced.artworkData == newArtwork)
        #expect(replaced.editsArtwork)

        let removal = MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "")
        let removed = MediaMetadataEditPatch(fields: [.artwork], draft: removal).applying(to: original)
        #expect(removed.artworkData == nil)
        #expect(removed.editsArtwork)
    }

    @Test func metadataEditPatchWithoutFieldsIsEmptyAndLeavesDraftUnchanged() {
        let original = MediaMetadataEditDraft(title: "Title", artist: "Artist", album: "Album", genre: "Genre")
        let draft = MediaMetadataEditDraft(
            title: "New Title", artist: "New Artist", album: "New Album", genre: "New Genre"
        )
        let patch = MediaMetadataEditPatch(draft: draft)

        #expect(patch.isEmpty)
        #expect(patch.applying(to: original) == original)
    }

    @Test func librarySortFieldSortsStringsInRequestedDirection() {
        let first = makeMediaItem(id: 1, title: "Beta", artist: "Composer B")
        let second = makeMediaItem(id: 2, title: "Alpha", artist: "Composer C")
        let third = makeMediaItem(id: 3, title: "Gamma", artist: "Composer A")
        let items = [first, second, third]

        #expect(LibrarySortField.title.sorted(items, direction: .ascending).map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(
            LibrarySortField.artist.sorted(items, direction: .descending).map(\.artist)
                == ["Composer C", "Composer B", "Composer A"]
        )
    }

    @Test func librarySearchFilterMatchesAlbumUsingPartialCaseInsensitiveText() {
        let item = makeMediaItem(id: 1, title: "Song", album: "Kind of Blue")
        let filter = LibrarySearchFilter(album: "OF blue")

        #expect(filter.matches(item))
    }

    @Test func librarySearchFilterMatchesTitleComposerAndAlbumArtist() {
        let item = makeMediaItem(
            id: 1,
            title: "Clair de Lune",
            albumArtist: "Debussy Collection",
            composer: "Claude Debussy"
        )

        #expect(LibrarySearchFilter(title: "CLAIR").matches(item))
        #expect(LibrarySearchFilter(albumArtist: "collection").matches(item))
        #expect(LibrarySearchFilter(composer: "claude").matches(item))
        #expect(LibrarySearchFilter(composer: "Mozart").matches(item) == false)
    }

    @Test func librarySearchTextMatchesComposerAndAlbumArtist() {
        let item = makeMediaItem(
            id: 1,
            title: "Track",
            albumArtist: "The Ensemble",
            composer: "John Williams"
        )

        #expect(LibrarySearchFilter().matches(item, searchText: "ensemble"))
        #expect(LibrarySearchFilter().matches(item, searchText: "williams"))
    }

    @Test func librarySearchFilterSupportsAndAcrossArtistAndGenre() {
        let matching = makeMediaItem(id: 1, title: "One", artist: "Miles Davis", genre: "Jazz")
        let wrongGenre = makeMediaItem(id: 2, title: "Two", artist: "Miles Davis", genre: "Rock")
        let filter = LibrarySearchFilter(artist: "miles", genre: "jazz", matchMode: .all)

        #expect(filter.matches(matching))
        #expect(filter.matches(wrongGenre) == false)
    }

    @Test func librarySearchFilterSupportsOrAcrossArtistAndGenre() {
        let artistMatch = makeMediaItem(id: 1, title: "One", artist: "Miles Davis", genre: "Jazz")
        let genreMatch = makeMediaItem(id: 2, title: "Two", artist: "Someone Else", genre: "Ambient")
        let noMatch = makeMediaItem(id: 3, title: "Three", artist: "Someone Else", genre: "Rock")
        let filter = LibrarySearchFilter(artist: "miles", genre: "ambient", matchMode: .any)

        #expect(filter.matches(artistMatch))
        #expect(filter.matches(genreMatch))
        #expect(filter.matches(noMatch) == false)
    }

    @Test func librarySearchTextAndAdvancedFiltersAreCombinedWithAnd() {
        let matching = makeMediaItem(id: 1, title: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue")
        let wrongSearchText = makeMediaItem(id: 2, title: "So What", artist: "Miles Davis", album: "Kind of Blue")
        let filter = LibrarySearchFilter(album: "kind of blue")

        #expect(filter.matches(matching, searchText: "green"))
        #expect(filter.matches(wrongSearchText, searchText: "green") == false)
    }

    @Test func emptyLibrarySearchFilterMatchesEveryItemAndClearRetainsMode() {
        let item = makeMediaItem(id: 1, title: "Song")
        var filter = LibrarySearchFilter(
            title: "Title",
            album: "Album",
            artist: "Artist",
            albumArtist: "Album Artist",
            composer: "Composer",
            genre: "Jazz",
            matchMode: .any
        )

        #expect(filter.activeCriteriaCount == 6)

        filter.clear()

        #expect(filter.isActive == false)
        #expect(filter.activeCriteriaCount == 0)
        #expect(filter.matchMode == .any)
        #expect(filter.matches(item))
    }

    @Test func librarySortFieldSortsDateAndDurationValues() {
        let first = makeMediaItem(id: 1, title: "One", duration: 120, addedAt: Date(timeIntervalSince1970: 20))
        let second = makeMediaItem(id: 2, title: "Two", duration: 60, addedAt: Date(timeIntervalSince1970: 10))
        let third = makeMediaItem(id: 3, title: "Three", duration: 180, addedAt: Date(timeIntervalSince1970: 30))
        let items = [first, second, third]

        #expect(LibrarySortField.dateAdded.sorted(items, direction: .ascending).map(\.title) == ["Two", "One", "Three"])
        #expect(LibrarySortField.duration.sorted(items, direction: .descending).map(\.title) == ["Three", "One", "Two"])
    }

    @Test func librarySortFieldSortsAdditionalMetadataColumns() {
        let first = makeMediaItem(id: 1, title: "One", fileName: "b.mp3")
        first.trackNumber = "10/12"
        first.year = "2001"
        first.albumArtist = "Band B"

        let second = makeMediaItem(id: 2, title: "Two", fileName: "a.mp3")
        second.trackNumber = "2/12"
        second.year = "1999"
        second.albumArtist = "Band A"

        let items = [first, second]

        #expect(LibrarySortField.trackNumber.sorted(items, direction: .ascending).map(\.title) == ["Two", "One"])
        #expect(LibrarySortField.year.sorted(items, direction: .descending).map(\.title) == ["One", "Two"])
        #expect(LibrarySortField.albumArtist.sorted(items, direction: .ascending).map(\.title) == ["Two", "One"])
        #expect(LibrarySortField.fileName.sorted(items, direction: .ascending).map(\.title) == ["Two", "One"])
    }

    @Test func mediaItemDisplaysFileExtensionAsContentType() {
        #expect(makeMediaItem(id: 1, title: "MP3", fileName: "song.mp3").displayContentType == "MP3")
        #expect(makeMediaItem(id: 2, title: "AAC", fileName: "song.AAC").displayContentType == "AAC")
        #expect(makeMediaItem(id: 3, title: "AIFF", fileName: "song.aiff").displayContentType == "AIFF")
        #expect(makeMediaItem(id: 4, title: "Unknown", fileName: "song").displayContentType == "-")
    }

    @Test func librarySortFieldSortsContentTypes() {
        let mp3 = makeMediaItem(id: 1, title: "MP3", fileName: "song.mp3")
        let aiff = makeMediaItem(id: 2, title: "AIFF", fileName: "song.aiff")
        let aac = makeMediaItem(id: 3, title: "AAC", fileName: "song.aac")

        #expect(
            LibrarySortField.contentType.sorted([mp3, aiff, aac], direction: .ascending).map(\.title)
                == ["AAC", "AIFF", "MP3"]
        )
    }
}

@MainActor
struct MediaExportTests {
    @Test func mp4TitleReaderFindsUdtaMetaIlstName() throws {
        let title = "Movie Title"
        let dataPayload = Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(title.utf8)
        let nameBox = mp4Box(type: [0xA9, 0x6E, 0x61, 0x6D], payload: mp4Box(type: "data", payload: dataPayload))
        let ilstBox = mp4Box(type: "ilst", payload: nameBox)
        let metaBox = mp4Box(type: "meta", payload: Data([0, 0, 0, 0]) + ilstBox)
        let udtaBox = mp4Box(type: "udta", payload: metaBox)
        let moovBox = mp4Box(type: "moov", payload: udtaBox)
        let ftypBox = mp4Box(type: "ftyp", payload: Data("isom".utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try (ftypBox + moovBox).write(to: url)

        #expect(try MP4TitleReader.title(in: url) == title)
    }

    @Test func timestampFallbackUsesOnlyAllowedCharacters() {
        let name = MediaExportNaming.timestampName(date: Date(timeIntervalSince1970: 0), index: 12)
        let allowed = CharacterSet(charactersIn: "0123456789-_")

        #expect(name.hasSuffix("_012"))
        #expect(name.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test func pathComponentSanitizerUsesUnnamedAlbumFallback() {
        #expect(
            MediaExportNaming.sanitizedPathComponent("", fallback: MediaExportNaming.unnamedAlbumName)
                == L10n.string("Untitled Album")
        )
        #expect(MediaExportNaming.sanitizedPathComponent("Album/Name:One", fallback: "Fallback") == "Album Name One")
    }

    private func mp4Box(type: String, payload: Data) -> Data {
        mp4Box(type: Array(type.utf8), payload: payload)
    }

    private func mp4Box(type: [UInt8], payload: Data) -> Data {
        var data = Data()
        var size = UInt32(payload.count + 8).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(contentsOf: type)
        data.append(payload)
        return data
    }
}

@MainActor
struct ID3TagWriterTests {
    @Test func writesEditableFramesAndPreservesOtherFrames() throws {
        let artworkPayload = Data([0x00, 0x01, 0x02, 0x03])
        let originalTag = id3Tag(frames: [
            id3Frame(id: "TIT2", payload: id3TextPayload("Old Title")),
            id3Frame(id: "APIC", payload: artworkPayload)
        ])
        let audioPayload = Data([0xFF, 0xFB, 0x90, 0x64])
        let url = temporaryMP3URL()
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try (originalTag + audioPayload).write(to: url)
        try ID3TagWriter.write(
            MediaMetadataEditDraft(
                title: "New Title",
                artist: "New Artist",
                album: "New Album",
                genre: "Rock",
                year: "2017",
                trackNumber: "31/32",
                comment: "New Comment",
                albumArtist: "Album Artist",
                composer: "Composer",
                discNumber: "3/3",
                isCompilation: true
            ),
            to: url
        )

        let written = try Data(contentsOf: url)
        let frames = try id3FramePayloads(in: written)
        #expect(id3TextValue(frames["TIT2"]) == "New Title")
        #expect(id3TextValue(frames["TPE1"]) == "New Artist")
        #expect(id3TextValue(frames["TALB"]) == "New Album")
        #expect(id3TextValue(frames["TCON"]) == "Rock")
        #expect(id3TextValue(frames["TYER"]) == "2017")
        #expect(id3TextValue(frames["TRCK"]) == "31/32")
        #expect(id3CommentValue(frames["COMM"]) == "New Comment")
        #expect(id3TextValue(frames["TPE2"]) == "Album Artist")
        #expect(id3TextValue(frames["TCOM"]) == "Composer")
        #expect(id3TextValue(frames["TPOS"]) == "3/3")
        #expect(id3TextValue(frames["TCMP"]) == "1")
        #expect(frames["APIC"] == artworkPayload)
        #expect(written.suffix(audioPayload.count) == audioPayload)
    }

    @Test func editsOnlyUnsynchronizedLyricsWhenRequested() throws {
        let originalTag = id3Tag(frames: [
            id3Frame(id: "TIT2", payload: id3TextPayload("Original Title")),
            id3Frame(id: "USLT", payload: id3LyricsPayload("Original lyrics"))
        ])
        let audioPayload = Data([0xFF, 0xFB, 0x90, 0x64])
        let url = temporaryMP3URL()
        defer { try? FileManager.default.removeItem(at: url) }

        try (originalTag + audioPayload).write(to: url)
        try ID3TagWriter.write(
            MediaMetadataEditDraft(
                title: "",
                artist: "",
                album: "",
                genre: "",
                lyrics: "Updated lyrics\nSecond line",
                editsTextMetadata: false,
                editsLyrics: true
            ),
            to: url
        )

        var frames = try id3FramePayloads(in: Data(contentsOf: url))
        #expect(id3TextValue(frames["TIT2"]) == "Original Title")
        #expect(id3LyricsValue(frames["USLT"]) == "Updated lyrics\nSecond line")

        try ID3TagWriter.write(
            MediaMetadataEditDraft(
                title: "",
                artist: "",
                album: "",
                genre: "",
                editsTextMetadata: false,
                editsLyrics: true
            ),
            to: url
        )

        frames = try id3FramePayloads(in: Data(contentsOf: url))
        #expect(id3TextValue(frames["TIT2"]) == "Original Title")
        #expect(frames["USLT"] == nil)
    }

    @Test func writesID3v22EditableFramesAndPreservesOtherFrames() throws {
        let picturePayload = Data([0x00, 0x01, 0x02, 0x03])
        let originalTag = id3Tag(version: 2, frames: [
            id3Frame(id: "TT2", payload: id3TextPayload("Old Title")),
            id3Frame(id: "PIC", payload: picturePayload)
        ])
        let audioPayload = Data([0xFF, 0xFB, 0x90, 0x64])
        let url = temporaryMP3URL()
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try (originalTag + audioPayload).write(to: url)
        try ID3TagWriter.write(
            MediaMetadataEditDraft(
                title: "New Title",
                artist: "New Artist",
                album: "New Album",
                genre: "Wind Band",
                year: "1999",
                trackNumber: "2/12",
                comment: "v22 Comment",
                albumArtist: "v22 Album Artist",
                composer: "v22 Composer",
                discNumber: "1/2",
                isCompilation: true
            ),
            to: url
        )

        let written = try Data(contentsOf: url)
        let frames = try id3FramePayloads(in: written)
        #expect(written[3] == 0x02)
        #expect(id3TextValue(frames["TT2"]) == "New Title")
        #expect(id3TextValue(frames["TP1"]) == "New Artist")
        #expect(id3TextValue(frames["TAL"]) == "New Album")
        #expect(id3TextValue(frames["TCO"]) == "Wind Band")
        #expect(id3TextValue(frames["TYE"]) == "1999")
        #expect(id3TextValue(frames["TRK"]) == "2/12")
        #expect(id3CommentValue(frames["COM"]) == "v22 Comment")
        #expect(id3TextValue(frames["TP2"]) == "v22 Album Artist")
        #expect(id3TextValue(frames["TCM"]) == "v22 Composer")
        #expect(id3TextValue(frames["TPA"]) == "1/2")
        #expect(id3TextValue(frames["TCP"]) == "1")
        #expect(frames["PIC"] == picturePayload)
        #expect(written.suffix(audioPayload.count) == audioPayload)
    }

    @Test func readsID3v22EditableFrames() throws {
        let originalTag = id3Tag(version: 2, frames: [
            id3Frame(id: "TT2", payload: id3Latin1TextPayload("Title")),
            id3Frame(id: "TP1", payload: id3Latin1TextPayload("Artist")),
            id3Frame(id: "TAL", payload: id3Latin1TextPayload("Album")),
            id3Frame(id: "TCO", payload: id3Latin1TextPayload("Pop")),
            id3Frame(id: "TYE", payload: id3Latin1TextPayload("2017")),
            id3Frame(id: "TRK", payload: id3Latin1TextPayload("31/32")),
            id3Frame(id: "TP2", payload: id3Latin1TextPayload("ATLUS SOUND TEAM")),
            id3Frame(id: "TCM", payload: id3Latin1TextPayload("ATLUS")),
            id3Frame(id: "TPA", payload: id3Latin1TextPayload("3/3")),
            id3Frame(id: "TCP", payload: id3Latin1TextPayload("1"))
        ])
        let url = temporaryMP3URL()
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try originalTag.write(to: url)
        let values = try #require(try ID3TagWriter.readMetadata(from: url))

        #expect(values.title == "Title")
        #expect(values.artist == "Artist")
        #expect(values.album == "Album")
        #expect(values.genre == "Pop")
        #expect(values.year == "2017")
        #expect(values.trackNumber == "31/32")
        #expect(values.albumArtist == "ATLUS SOUND TEAM")
        #expect(values.composer == "ATLUS")
        #expect(values.discNumber == "3/3")
        #expect(values.isCompilation == true)
    }

    @Test func addsID3TagWhenMissing() throws {
        let audioPayload = Data([0xFF, 0xFB, 0x90, 0x64])
        let url = temporaryMP3URL()
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try audioPayload.write(to: url)
        try ID3TagWriter.write(
            MediaMetadataEditDraft(title: "New Title", artist: "New Artist", album: "", genre: ""),
            to: url
        )

        let written = try Data(contentsOf: url)
        let frames = try id3FramePayloads(in: written)
        #expect(id3TextValue(frames["TIT2"]) == "New Title")
        #expect(id3TextValue(frames["TPE1"]) == "New Artist")
        #expect(frames["TALB"] == nil)
        #expect(frames["TCON"] == nil)
        #expect(written.suffix(audioPayload.count) == audioPayload)
    }

    @Test func replacesAndRemovesID3Artwork() throws {
        let oldArtwork = Data([0xFF, 0xD8, 0x01, 0x02])
        let newArtwork = Data([0x89, 0x50, 0x4E, 0x47, 0x03, 0x04])
        let originalTag = id3Tag(frames: [
            id3Frame(id: "APIC", payload: id3ArtworkPayload(oldArtwork))
        ])
        let url = temporaryMP3URL()
        defer { try? FileManager.default.removeItem(at: url) }

        try originalTag.write(to: url)
        try ID3TagWriter.write(
            MediaMetadataEditDraft(
                title: "Title",
                artist: "",
                album: "",
                genre: "",
                artworkData: newArtwork,
                editsArtwork: true
            ),
            to: url
        )

        var frames = try id3FramePayloads(in: Data(contentsOf: url))
        #expect(frames["APIC"]?.suffix(newArtwork.count) == newArtwork)
        #expect(frames["APIC"]?.contains(oldArtwork) == false)

        try ID3TagWriter.write(
            MediaMetadataEditDraft(
                title: "Title",
                artist: "",
                album: "",
                genre: "",
                editsArtwork: true
            ),
            to: url
        )
        frames = try id3FramePayloads(in: Data(contentsOf: url))
        #expect(frames["APIC"] == nil)
    }

    @Test func blankDraftValuesRemoveWritableFramesAndUseModelFallbacks() throws {
        let originalTag = id3Tag(frames: [
            id3Frame(id: "TIT2", payload: id3TextPayload("Old Title")),
            id3Frame(id: "TCON", payload: id3TextPayload("Old Genre")),
            id3Frame(id: "TYER", payload: id3TextPayload("2010")),
            id3Frame(id: "TRCK", payload: id3TextPayload("1")),
            id3Frame(id: "COMM", payload: id3CommentPayload("Old Comment")),
            id3Frame(id: "TPE2", payload: id3TextPayload("Old Album Artist")),
            id3Frame(id: "TCOM", payload: id3TextPayload("Old Composer")),
            id3Frame(id: "TPOS", payload: id3TextPayload("1/1")),
            id3Frame(id: "TCMP", payload: id3TextPayload("1"))
        ])
        let url = temporaryMP3URL()
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try originalTag.write(to: url)
        let draft = MediaMetadataEditDraft(title: "", artist: "", album: "", genre: "")
        try ID3TagWriter.write(draft, to: url)

        let written = try Data(contentsOf: url)
        let frames = try id3FramePayloads(in: written)
        let modelValues = draft.normalizedModelValues(fileURL: url)

        #expect(frames["TIT2"] == nil)
        #expect(frames["TCON"] == nil)
        #expect(frames["TYER"] == nil)
        #expect(frames["TRCK"] == nil)
        #expect(frames["COMM"] == nil)
        #expect(frames["TPE2"] == nil)
        #expect(frames["TCOM"] == nil)
        #expect(frames["TPOS"] == nil)
        #expect(frames["TCMP"] == nil)
        #expect(modelValues.title == url.deletingPathExtension().lastPathComponent)
        #expect(modelValues.artist == "Unknown Artist")
        #expect(modelValues.album == "Unknown Album")
        #expect(modelValues.genre == nil)
        #expect(modelValues.year == nil)
        #expect(modelValues.trackNumber == nil)
        #expect(modelValues.comment == nil)
        #expect(modelValues.albumArtist == nil)
        #expect(modelValues.composer == nil)
        #expect(modelValues.discNumber == nil)
        #expect(modelValues.isCompilation == false)
    }

    @Test func rejectsUnsupportedFileExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try Data().write(to: url)

        #expect(throws: MediaMetadataEditError.unsupportedFileFormat) {
            try ID3TagWriter.write(MediaMetadataEditDraft(title: "Title", artist: "", album: "", genre: ""), to: url)
        }
    }
}

@MainActor
struct MP4MetadataWriterTests {
    @Test func readsPurchaseStyleSortMetadataAsDisplayFallbacks() throws {
        var itemList = Data()
        itemList.append(mp4MetadataItem(type: Array("sonm".utf8), value: "Purchase Title"))
        itemList.append(mp4MetadataItem(type: Array("soar".utf8), value: "Purchase Artist"))
        itemList.append(mp4MetadataItem(type: Array("soal".utf8), value: "Purchase Album"))
        itemList.append(mp4MetadataItem(type: Array("soaa".utf8), value: "Purchase Album Artist"))
        itemList.append(mp4MetadataItem(type: Array("soco".utf8), value: "Purchase Composer"))
        itemList.append(mp4MetadataItem(type: [0xA9, 0x64, 0x61, 0x79], value: "2026-04-01T12:00:00Z"))
        let ilstBox = mp4TestBox(type: "ilst", payload: itemList)
        let metaBox = mp4TestBox(type: "meta", payload: Data([0, 0, 0, 0]) + ilstBox)
        let udtaBox = mp4TestBox(type: "udta", payload: metaBox)
        let moovBox = mp4TestBox(type: "moov", payload: udtaBox)
        let url = temporaryMediaURL(extension: "m4a")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try moovBox.write(to: url)

        let metadata = try #require(try MP4MetadataReader.read(from: url))
        #expect(metadata.values.title == "Purchase Title")
        #expect(metadata.values.artist == "Purchase Artist")
        #expect(metadata.values.album == "Purchase Album")
        #expect(metadata.values.albumArtist == "Purchase Album Artist")
        #expect(metadata.values.composer == "Purchase Composer")
        #expect(metadata.values.year == "2026")
        #expect(metadata.usedSortMetadataFallback)
    }

    @Test func readsM4AEmbeddedMetadataArtworkAndLyrics() throws {
        let artwork = Data([0xFF, 0xD8, 0xFF, 0xE0])
        var itemList = Data()
        itemList.append(mp4MetadataItem(type: Array("sonm".utf8), value: "Sort Title"))
        itemList.append(mp4MetadataItem(type: Array("soar".utf8), value: "Sort Artist"))
        itemList.append(mp4MetadataItem(type: Array("soal".utf8), value: "Sort Album"))
        itemList.append(mp4MetadataItem(type: [0xA9, 0x6E, 0x61, 0x6D], value: "Song Title"))
        itemList.append(mp4MetadataItem(type: [0xA9, 0x41, 0x52, 0x54], value: "Song Artist"))
        itemList.append(mp4MetadataItem(type: [0xA9, 0x61, 0x6C, 0x62], value: "Song Album"))
        itemList.append(mp4MetadataItem(type: [0xA9, 0x67, 0x65, 0x6E], value: "Rock"))
        itemList.append(mp4MetadataItem(type: [0xA9, 0x64, 0x61, 0x79], value: "2026"))
        itemList.append(mp4MetadataItem(type: Array("aART".utf8), value: "Album Artist"))
        itemList.append(mp4MetadataItem(type: [0xA9, 0x77, 0x72, 0x74], value: "Composer"))
        itemList.append(mp4MetadataItem(type: [0xA9, 0x6C, 0x79, 0x72], value: "First line\nSecond line"))
        itemList.append(mp4ArtworkItem(artwork))
        let ilstBox = mp4TestBox(type: "ilst", payload: itemList)
        let metaBox = mp4TestBox(type: "meta", payload: Data([0, 0, 0, 0]) + ilstBox)
        let udtaBox = mp4TestBox(type: "udta", payload: metaBox)
        let moovBox = mp4TestBox(type: "moov", payload: udtaBox)
        let ftypBox = mp4TestBox(type: "ftyp", payload: Data("M4A ".utf8))
        let url = temporaryMediaURL(extension: "m4a")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try (ftypBox + moovBox).write(to: url)

        let metadata = try #require(try MP4MetadataReader.read(from: url))
        #expect(metadata.values.title == "Song Title")
        #expect(metadata.values.artist == "Song Artist")
        #expect(metadata.values.album == "Song Album")
        #expect(metadata.values.genre == "Rock")
        #expect(metadata.values.year == "2026")
        #expect(metadata.values.albumArtist == "Album Artist")
        #expect(metadata.values.composer == "Composer")
        #expect(metadata.lyrics == "First line\nSecond line")
        #expect(metadata.artworkData == artwork)
        #expect(metadata.usedSortMetadataFallback == false)
    }

    #if os(macOS)
    @Test func musicLibraryLookupAppleScriptCompiles() throws {
        let source = MusicLibraryMetadataProvider.appleScriptSource
        let script = try #require(NSAppleScript(source: source))
        var errorInfo: NSDictionary?

        #expect(script.compileAndReturnError(&errorInfo))
        #expect(errorInfo == nil)
    }

    #endif

    @Test func writesM4AEditableMetadataAndPreservesOtherItems() throws {
        let coverPayload = Data([0x0D, 0x0E, 0x0A, 0x0D])
        let ilstBox = mp4TestBox(type: "ilst", payload:
            mp4MetadataItem(type: [0xA9, 0x6E, 0x61, 0x6D], value: "Old Title")
            + mp4MetadataItem(type: [0xA9, 0x41, 0x52, 0x54], value: "Old Artist")
            + mp4TestBox(type: "covr", payload: coverPayload)
        )
        let metaBox = mp4TestBox(type: "meta", payload: Data([0, 0, 0, 0]) + ilstBox)
        let udtaBox = mp4TestBox(type: "udta", payload: metaBox)
        let moovBox = mp4TestBox(type: "moov", payload: udtaBox)
        let ftypBox = mp4TestBox(type: "ftyp", payload: Data("M4A ".utf8))
        let mdatBox = mp4TestBox(type: "mdat", payload: Data([0x00, 0x01, 0x02]))
        let url = temporaryMediaURL(extension: "m4a")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try (ftypBox + moovBox + mdatBox).write(to: url)
        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(
                title: "New Title",
                artist: "New Artist",
                album: "New Album",
                genre: "Concert Band",
                year: "2017",
                trackNumber: "31/32",
                comment: "New Comment",
                albumArtist: "Album Artist",
                composer: "Composer",
                discNumber: "3/3",
                isCompilation: true
            ),
            to: url
        )

        let written = try Data(contentsOf: url)
        let values = try mp4MetadataValues(in: written)
        #expect(values["©nam"] == "New Title")
        #expect(values["©ART"] == "New Artist")
        #expect(values["©alb"] == "New Album")
        #expect(values["©gen"] == "Concert Band")
        #expect(values["©day"] == "2017")
        #expect(values["trkn"] == "31/32")
        #expect(values["©cmt"] == "New Comment")
        #expect(values["aART"] == "Album Artist")
        #expect(values["©wrt"] == "Composer")
        #expect(values["disk"] == "3/3")
        #expect(values["cpil"] == "1")
        #expect(values["covrData"] == coverPayload.base64EncodedString())
        #expect(try MP4TitleReader.title(in: url) == "New Title")
    }

    @Test func editsOnlyLyricsItemWhenRequested() throws {
        let ilstBox = mp4TestBox(type: "ilst", payload:
            mp4MetadataItem(type: [0xA9, 0x6E, 0x61, 0x6D], value: "Original Title")
            + mp4MetadataItem(type: [0xA9, 0x6C, 0x79, 0x72], value: "Original lyrics")
        )
        let metaBox = mp4TestBox(type: "meta", payload: Data([0, 0, 0, 0]) + ilstBox)
        let moovBox = mp4TestBox(type: "moov", payload: mp4TestBox(type: "udta", payload: metaBox))
        let url = temporaryMediaURL(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        try moovBox.write(to: url)
        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(
                title: "",
                artist: "",
                album: "",
                genre: "",
                lyrics: "Updated lyrics\nSecond line",
                editsTextMetadata: false,
                editsLyrics: true
            ),
            to: url
        )

        var values = try mp4MetadataValues(in: Data(contentsOf: url))
        #expect(values["©nam"] == "Original Title")
        #expect(values["©lyr"] == "Updated lyrics\nSecond line")

        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(
                title: "",
                artist: "",
                album: "",
                genre: "",
                editsTextMetadata: false,
                editsLyrics: true
            ),
            to: url
        )

        values = try mp4MetadataValues(in: Data(contentsOf: url))
        #expect(values["©nam"] == "Original Title")
        #expect(values["©lyr"] == nil)
    }

    @Test func growsMoovBeforeMdatAndAdjustsStcoOffsets() throws {
        let ftypBox = mp4TestBox(type: "ftyp", payload: Data("M4A ".utf8))
        let mdatBox = mp4TestBox(type: "mdat", payload: Data([0x00, 0x01, 0x02, 0x03]))
        let oldIlstBox = mp4TestBox(type: "ilst", payload: mp4MetadataItem(type: [0xA9, 0x6E, 0x61, 0x6D], value: "A"))
        let metaBox = mp4TestBox(type: "meta", payload: Data([0, 0, 0, 0]) + oldIlstBox)
        let udtaBox = mp4TestBox(type: "udta", payload: metaBox)
        let placeholderStco = mp4StcoBox(offset: 0)
        let stblBox = mp4TestBox(type: "stbl", payload: placeholderStco)
        let minfBox = mp4TestBox(type: "minf", payload: stblBox)
        let mdiaBox = mp4TestBox(type: "mdia", payload: minfBox)
        let trakBox = mp4TestBox(type: "trak", payload: mdiaBox)
        let placeholderMoovBox = mp4TestBox(type: "moov", payload: trakBox + udtaBox)
        let mdatPayloadOffset = UInt32(ftypBox.count + placeholderMoovBox.count + 8)
        let stcoBox = mp4StcoBox(offset: mdatPayloadOffset)
        let moovBox = mp4TestBox(type: "moov", payload:
            mp4TestBox(type: "trak", payload:
                mp4TestBox(type: "mdia", payload:
                    mp4TestBox(type: "minf", payload:
                        mp4TestBox(type: "stbl", payload: stcoBox)
                    )
                )
            )
            + udtaBox
        )
        let url = temporaryMediaURL(extension: "m4a")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try (ftypBox + moovBox + mdatBox).write(to: url)
        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(
                title: "A much longer title that grows the moov box", artist: "Artist", album: "Album", genre: "Genre"
            ),
            to: url
        )

        let written = try Data(contentsOf: url)
        #expect(try mp4FirstStcoOffset(in: written) == UInt32(mp4MdatPayloadOffset(in: written)))
    }

    @Test func replacesAndRemovesM4AArtwork() throws {
        let oldArtwork = Data([0xFF, 0xD8, 0x01, 0x02])
        let newArtwork = Data([0x89, 0x50, 0x4E, 0x47, 0x03, 0x04])
        let ilstBox = mp4TestBox(type: "ilst", payload: mp4ArtworkItem(oldArtwork))
        let metaBox = mp4TestBox(type: "meta", payload: Data([0, 0, 0, 0]) + ilstBox)
        let moovBox = mp4TestBox(type: "moov", payload: mp4TestBox(type: "udta", payload: metaBox))
        let url = temporaryMediaURL(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        try moovBox.write(to: url)
        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(
                title: "Title",
                artist: "",
                album: "",
                genre: "",
                artworkData: newArtwork,
                editsArtwork: true
            ),
            to: url
        )
        var values = try mp4MetadataValues(in: Data(contentsOf: url))
        #expect(values["covrData"] == newArtwork.base64EncodedString())

        try MP4MetadataWriter.write(
            MediaMetadataEditDraft(
                title: "Title",
                artist: "",
                album: "",
                genre: "",
                editsArtwork: true
            ),
            to: url
        )
        values = try mp4MetadataValues(in: Data(contentsOf: url))
        #expect(values["covrData"] == nil)
    }
}

@MainActor
struct AIFFMetadataWriterTests {
    @Test func writesAIFFID3ChunkAndPreservesAudioChunks() throws {
        let artworkPayload = Data([0x00, 0x01, 0x02, 0x03])
        let originalID3 = id3Tag(frames: [
            id3Frame(id: "TIT2", payload: id3TextPayload("Old Title")),
            id3Frame(id: "APIC", payload: artworkPayload)
        ])
        let commonPayload = Data([0x00, 0x02, 0x00, 0x10, 0x40, 0x0E, 0xAC, 0x44, 0x00, 0x00])
        let soundPayload = Data([0x00, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC])
        let url = temporaryMediaURL(extension: "aiff")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try aiffFile(chunks: [
            aiffChunk(id: "COMM", payload: commonPayload),
            aiffChunk(id: "ID3 ", payload: originalID3),
            aiffChunk(id: "SSND", payload: soundPayload)
        ]).write(to: url)

        try AIFFMetadataWriter.write(
            MediaMetadataEditDraft(title: "New Title", artist: "New Artist", album: "New Album", genre: "Classical"),
            to: url
        )

        let written = try Data(contentsOf: url)
        let id3Payload = try aiffChunkPayload(id: "ID3 ", in: written)
        let id3Data = try #require(id3Payload)
        let frames = try id3FramePayloads(in: id3Data)

        #expect(aiffFormType(in: written) == "AIFF")
        #expect(aiffFormSize(in: written) == written.count - 8)
        #expect(try aiffChunkPayload(id: "COMM", in: written) == commonPayload)
        #expect(try aiffChunkPayload(id: "SSND", in: written) == soundPayload)
        #expect(id3TextValue(frames["TIT2"]) == "New Title")
        #expect(id3TextValue(frames["TPE1"]) == "New Artist")
        #expect(id3TextValue(frames["TALB"]) == "New Album")
        #expect(id3TextValue(frames["TCON"]) == "Classical")
        #expect(frames["APIC"] == artworkPayload)
    }

    @Test func addsID3ChunkToAIFCWhenMissing() throws {
        let soundPayload = Data([0x00, 0x00, 0x00, 0x00, 0x11])
        let url = temporaryMediaURL(extension: "aifc")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try aiffFile(formType: "AIFC", chunks: [
            aiffChunk(id: "SSND", payload: soundPayload)
        ]).write(to: url)

        try AIFFMetadataWriter.write(
            MediaMetadataEditDraft(title: "AIFC Title", artist: "AIFC Artist", album: "", genre: ""),
            to: url
        )

        let written = try Data(contentsOf: url)
        let id3Payload = try aiffChunkPayload(id: "ID3 ", in: written)
        let id3Data = try #require(id3Payload)
        let frames = try id3FramePayloads(in: id3Data)

        #expect(aiffFormType(in: written) == "AIFC")
        #expect(aiffFormSize(in: written) == written.count - 8)
        #expect(try aiffChunkPayload(id: "SSND", in: written) == soundPayload)
        #expect(id3TextValue(frames["TIT2"]) == "AIFC Title")
        #expect(id3TextValue(frames["TPE1"]) == "AIFC Artist")
        #expect(frames["TALB"] == nil)
        #expect(frames["TCON"] == nil)
    }

    @Test func embedsLyricsWithoutChangingOtherAIFFTags() throws {
        let originalID3 = id3Tag(frames: [
            id3Frame(id: "TIT2", payload: id3TextPayload("Original Title")),
            id3Frame(id: "USLT", payload: id3LyricsPayload("Original lyrics"))
        ])
        let soundPayload = Data([0x00, 0x00, 0x00, 0x00, 0x11])
        let url = temporaryMediaURL(extension: "aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        try aiffFile(chunks: [
            aiffChunk(id: "ID3 ", payload: originalID3),
            aiffChunk(id: "SSND", payload: soundPayload)
        ]).write(to: url)

        try AIFFMetadataWriter.write(
            MediaMetadataEditDraft(
                title: "",
                artist: "",
                album: "",
                genre: "",
                lyrics: "Updated lyrics",
                editsTextMetadata: false,
                editsLyrics: true
            ),
            to: url
        )

        let written = try Data(contentsOf: url)
        let id3Data = try #require(try aiffChunkPayload(id: "ID3 ", in: written))
        let frames = try id3FramePayloads(in: id3Data)
        #expect(id3TextValue(frames["TIT2"]) == "Original Title")
        #expect(id3LyricsValue(frames["USLT"]) == "Updated lyrics")
        #expect(try aiffChunkPayload(id: "SSND", in: written) == soundPayload)
    }
}

@MainActor
struct AudioFrameDataTests {
    @Test func silentCreatesMatchingStereoArraysAndPlaybackState() {
        let frame = AudioFrameData.silent(bandCount: 3, currentTime: 4.5, isPlaying: true)

        #expect(frame.bandsL == [0, 0, 0])
        #expect(frame.bandsR == [0, 0, 0])
        #expect(frame.peaksL == [0, 0, 0])
        #expect(frame.peaksR == [0, 0, 0])
        #expect(frame.rmsL == 0)
        #expect(frame.rmsR == 0)
        #expect(frame.peakRmsL == 0)
        #expect(frame.peakRmsR == 0)
        #expect(frame.currentTime == 4.5)
        #expect(frame.isPlaying)
    }
}

@MainActor
struct SpectrumFrameRateCounterTests {
    @Test func publishesRoundedFrameRateAfterWindowElapses() {
        var counter = SpectrumFrameRateCounter()

        #expect(counter.recordFrame(at: 0.0) == nil)
        #expect(counter.recordFrame(at: 0.1) == nil)
        #expect(counter.recordFrame(at: 0.2) == nil)
        #expect(counter.recordFrame(at: 0.3) == nil)
        #expect(counter.recordFrame(at: 0.4) == nil)
        #expect(counter.recordFrame(at: 0.5) == 10)
    }

    @Test func resetStartsANewWindow() {
        var counter = SpectrumFrameRateCounter()

        _ = counter.recordFrame(at: 0.0)
        _ = counter.recordFrame(at: 0.5)
        counter.reset()

        #expect(counter.recordFrame(at: 10.0) == nil)
        #expect(counter.recordFrame(at: 10.5) == 2)
    }
}

@MainActor
struct VisualizerResponseModeTests {
    @Test func modesExposeRequestedFrameRatesInPickerOrder() {
        #expect(VisualizerResponseMode.allCases == [.slow, .normal, .fast])
        #expect(VisualizerResponseMode.slow.framesPerSecond == 10)
        #expect(VisualizerResponseMode.normal.framesPerSecond == 30)
        #expect(VisualizerResponseMode.fast.framesPerSecond == 60)
    }

    @Test func defaultResponseModeIsNormal() {
        #expect(AppSettingsDefault.visualizerResponseMode == VisualizerResponseMode.normal.rawValue)
    }
}

struct AudioLoudnessNormalizerTests {
    @Test func measuresPCMFileAndCachesItsGain() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loudness-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let suiteName = "AudioLoudnessNormalizerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.1
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let measuredGain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, defaults: defaults)
        let cachedGain = try AudioLoudnessNormalizer.cachedOrMeasuredGain(for: url, defaults: defaults)

        #expect(abs(measuredGain - 2) < 0.01)
        #expect(cachedGain == measuredGain)
    }

    @Test func louderTrackIsAttenuatedToTargetLevel() {
        let gain = AudioLoudnessNormalizer.gainDecibels(
            forBlockMeanSquares: [pow(10, -10.0 / 10.0)],
            peakAmplitude: 0.9
        )

        #expect(abs(gain - (-8)) < 0.001)
    }

    @Test func quietTrackBoostIsLimitedByPeakHeadroom() {
        let gain = AudioLoudnessNormalizer.gainDecibels(
            forBlockMeanSquares: [pow(10, -30.0 / 10.0)],
            peakAmplitude: 0.5
        )

        #expect(abs(gain - 5.575) < 0.01)
    }

    @Test func silenceAndVeryQuietBlocksDoNotInfluenceMeasuredLevel() {
        let gain = AudioLoudnessNormalizer.gainDecibels(
            forBlockMeanSquares: [0, pow(10, -80.0 / 10.0), pow(10, -18.0 / 10.0)],
            peakAmplitude: 0.5
        )

        #expect(abs(gain) < 0.001)
    }
}

@MainActor
struct PlayerViewModelTests {
    @Test func pausedClockSynchronizesOnceAndResumesWithPlayback() async throws {
        let item = makeMediaItem(id: 1, title: "One", duration: 20)
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/one.mp3")], startsClock: true)
        fixture.player.play(item: item, in: [item])
        fixture.audio.currentTime = 2
        try await Task.sleep(for: .milliseconds(120))
        #expect(fixture.player.currentTime == 2)
        fixture.player.pause()
        fixture.audio.currentTime = 2.1
        try await Task.sleep(for: .milliseconds(650))
        #expect(fixture.player.currentTime == 2.1)
        fixture.audio.currentTime = 8
        try await Task.sleep(for: .milliseconds(650))
        #expect(fixture.player.currentTime == 2.1)

        fixture.player.resume()
        try await Task.sleep(for: .milliseconds(120))
        #expect(fixture.player.currentTime == 8)
        fixture.player.stop()
    }

    @Test func clockPublishesSubBeatChangesAndSecondBoundariesPromptly() async throws {
        let fixture = makePlayerFixture(startsClock: true)
        fixture.player.isPlaying = true
        fixture.audio.duration = 60
        for time in [0.98, 1.02, 1.27, 4.55] {
            fixture.audio.currentTime = time
            try await Task.sleep(for: .milliseconds(120))
            #expect(fixture.player.currentTime == time)
        }
        fixture.player.isPlaying = false
    }

    @Test func playAudioLoadsResolvedURLAndUpdatesState() {
        let item = makeMediaItem(id: 1, title: "One", duration: 12)
        let url = URL(fileURLWithPath: "/tmp/one.mp3")
        let fixture = makePlayerFixture(urlsByID: [item.id: url])

        fixture.player.play(item: item, in: [item])

        #expect(fixture.player.currentItem?.id == item.id)
        #expect(fixture.player.queue.map(\.id) == [item.id])
        #expect(fixture.player.isPlaying)
        #expect(fixture.player.duration == 12)
        #expect(fixture.player.isVideoMode == false)
        #expect(fixture.player.showVideoArea == false)
        #expect(fixture.audio.loadedURLs == [url])
        #expect(fixture.audio.playCallCount == 1)
        #expect(fixture.video.closeCallCount == 1)
    }

    @Test func playAudioReportsErrorWhenURLCannotBeResolved() {
        let item = makeMediaItem(id: 1, title: "Missing")
        let fixture = makePlayerFixture()

        fixture.player.play(item: item, in: [item])

        #expect(fixture.player.errorMessage == L10n.format("Could not open file: %@", "Missing"))
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.audio.loadedURLs.isEmpty)
        #expect(fixture.audio.playCallCount == 0)
    }

    @Test func nextAdvancesThroughQueueAndStopsAtEnd() {
        let first = makeMediaItem(id: 1, title: "One")
        let second = makeMediaItem(id: 2, title: "Two")
        let firstURL = URL(fileURLWithPath: "/tmp/one.mp3")
        let secondURL = URL(fileURLWithPath: "/tmp/two.mp3")
        let fixture = makePlayerFixture(urlsByID: [
            first.id: firstURL,
            second.id: secondURL
        ])

        fixture.player.play(item: first, in: [first, second])
        #expect(fixture.player.canSkipToNext)
        #expect(fixture.player.canSkipToPrevious == false)

        fixture.player.next()

        #expect(fixture.player.currentItem?.id == second.id)
        #expect(fixture.player.canSkipToNext == false)
        #expect(fixture.player.canSkipToPrevious)
        #expect(fixture.audio.loadedURLs == [firstURL, secondURL])

        fixture.player.next()

        #expect(fixture.player.currentItem?.id == second.id)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.audio.stopResets.last == true)
    }

    @Test func previousRestartsCurrentItemAfterThreeSecondsOtherwiseMovesBack() {
        let first = makeMediaItem(id: 1, title: "One")
        let second = makeMediaItem(id: 2, title: "Two")
        let firstURL = URL(fileURLWithPath: "/tmp/one.mp3")
        let secondURL = URL(fileURLWithPath: "/tmp/two.mp3")
        let fixture = makePlayerFixture(urlsByID: [
            first.id: firstURL,
            second.id: secondURL
        ])

        fixture.player.play(item: second, in: [first, second])
        fixture.player.currentTime = 4

        fixture.player.previous()

        #expect(fixture.player.currentItem?.id == second.id)
        #expect(fixture.audio.seekRequests.last?.time == 0)
        #expect(fixture.audio.seekRequests.last?.autoPlay == true)

        fixture.player.currentTime = 1
        fixture.player.previous()

        #expect(fixture.player.currentItem?.id == first.id)
        #expect(fixture.audio.loadedURLs == [secondURL, firstURL])
    }

    @Test func seekClampsToDurationAndPreservesPlaybackStateInAudioMode() {
        let item = makeMediaItem(id: 1, title: "One", duration: 10)
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/one.mp3")])
        fixture.player.play(item: item, in: [item])

        fixture.player.seek(to: -1)
        fixture.player.seek(to: 20)
        fixture.player.pause()
        fixture.player.seek(to: 5)

        #expect(fixture.audio.seekRequests.map(\.time) == [0, 10, 5])
        #expect(fixture.audio.seekRequests.map(\.autoPlay) == [true, true, false])
        #expect(fixture.player.currentTime == 5)
    }

    @Test func volumeClampsAndMuteRestoresLastAudibleVolume() {
        let fixture = makePlayerFixture()

        fixture.player.setVolume(1.5)
        fixture.player.setVolume(-0.5)
        fixture.player.toggleMuted()
        fixture.player.toggleMuted()

        #expect(fixture.player.volume == 1)
        #expect(fixture.player.isMuted == false)
        #expect(fixture.audio.volumes == [0.75, 1, 0, 0, 1])
        #expect(fixture.video.volumes == [0.75, 1, 0, 0, 1])
    }

    @Test func volumeNormalizationSettingUpdatesAudioEngine() {
        let fixture = makePlayerFixture()

        fixture.player.setVolumeNormalizationEnabled(true)
        fixture.player.setVolumeNormalizationEnabled(false)

        #expect(fixture.player.volumeNormalizationEnabled == false)
        #expect(fixture.audio.volumeNormalizationValues == [false, true, false])
    }

    @Test func equalizerUpdatesClampPersistAndReachAudioAndVideoEngines() throws {
        let suiteName = "PlayerViewModelEqualizerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = makePlayerFixture(equalizerDefaults: defaults)

        fixture.player.setEqualizerEnabled(true)
        fixture.player.setEqualizerPreamp(decibels: 30)
        fixture.player.setEqualizerBandGain(index: 3, decibels: -30)
        fixture.player.setEqualizerBandGain(index: -1, decibels: 8)
        fixture.player.setEqualizerReverbPreset(.largeHall)
        fixture.player.setEqualizerReverbWetDryMix(150)

        #expect(fixture.player.equalizer.isEnabled)
        #expect(fixture.player.equalizer.preampDecibels == 12)
        #expect(fixture.player.equalizer.bandGains[3] == -12)
        #expect(fixture.player.equalizer.reverbPreset == .largeHall)
        #expect(fixture.player.equalizer.reverbWetDryMix == 100)
        #expect(fixture.audio.equalizerValues.last == fixture.player.equalizer)
        #expect(fixture.video.equalizerValues.last == fixture.player.equalizer)
        #expect(EqualizerSettings.load(from: defaults) == fixture.player.equalizer)

        fixture.player.flattenEqualizer()

        #expect(fixture.player.equalizer.isEnabled)
        #expect(fixture.player.equalizer.preampDecibels == 0)
        #expect(fixture.player.equalizer.bandGains.allSatisfy { $0 == 0 })
        #expect(fixture.player.equalizer.reverbWetDryMix == 0)
    }

    @Test func equalizerPresetsCanBeAppliedSavedOverwrittenAndDeleted() throws {
        let suiteName = "PlayerViewModelEqualizerPresetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = makePlayerFixture(equalizerDefaults: defaults)

        fixture.player.applyEqualizerPreset(.concertHall)
        #expect(fixture.player.equalizer == BuiltInEqualizerPreset.concertHall.settings)
        #expect(fixture.player.activeEqualizerPresetName == BuiltInEqualizerPreset.concertHall.name)

        fixture.player.saveCurrentEqualizerPreset(named: "  My Hall  ")
        let savedPreset = try #require(fixture.player.userEqualizerPresets.first)
        #expect(savedPreset.name == "My Hall")
        #expect(UserEqualizerPreset.load(from: defaults) == fixture.player.userEqualizerPresets)

        fixture.player.setEqualizerBandGain(index: 0, decibels: 5)
        fixture.player.saveCurrentEqualizerPreset(named: "my hall")
        #expect(fixture.player.userEqualizerPresets.count == 1)
        #expect(fixture.player.userEqualizerPresets[0].settings.bandGains[0] == 5)

        fixture.player.setEqualizerEnabled(false)
        fixture.player.applyUserEqualizerPreset(id: savedPreset.id)
        #expect(fixture.player.equalizer.isEnabled)
        #expect(fixture.player.equalizer.bandGains[0] == 5)

        fixture.player.deleteUserEqualizerPreset(id: savedPreset.id)
        #expect(fixture.player.userEqualizerPresets.isEmpty)
        #expect(UserEqualizerPreset.load(from: defaults).isEmpty)
    }

    @Test func pitchSemitonesClampAndUpdateAudioEngineCents() {
        let fixture = makePlayerFixture()

        fixture.player.setPitchSemitones(8)
        fixture.player.setPitchSemitones(-9)
        fixture.player.setPitchSemitones(2)

        #expect(fixture.player.pitchSemitones == 2)
        #expect(fixture.audio.pitchCents == [600, -600, 200])
        #expect(fixture.player.hasPitchOrRateAdjustment)
    }

    @Test func playbackRateClampsQuantizesAndUpdatesAudioEngine() {
        let fixture = makePlayerFixture()

        fixture.player.setPlaybackRate(2.5)
        fixture.player.setPlaybackRate(0.01)
        fixture.player.setPlaybackRate(1.123)

        #expect(fixture.player.playbackRate == 1.1)
        #expect(fixture.audio.playbackRates == [2.0, 0.5, 1.1])
        #expect(fixture.player.hasPitchOrRateAdjustment)

        fixture.player.resetPitchAndRate()

        #expect(fixture.player.pitchSemitones == 0)
        #expect(fixture.player.playbackRate == 1.0)
        #expect(fixture.player.hasPitchOrRateAdjustment == false)
    }

    @Test func resetAudioEngineForwardsToAudioEngineWithoutTouchingPlayerState() {
        let fixture = makePlayerFixture()
        fixture.player.setPlaybackRate(1.5)

        fixture.player.resetAudioEngine()

        #expect(fixture.audio.resetEngineCallCount == 1)
        #expect(fixture.player.playbackRate == 1.5)
    }

    @Test func adjustedCopyTitleIncludesOnlyChangedValues() {
        #expect(
            PitchSpeedTextFormatter.adjustedTitle(baseTitle: "Song", pitchSemitones: 2, rate: 1.25)
                == "Song (\(L10n.format("Key%+d", 2)) ×1.25)"
        )
        #expect(
            PitchSpeedTextFormatter.adjustedTitle(baseTitle: "Song", pitchSemitones: 0, rate: 0.85) == "Song (×0.85)"
        )
        #expect(
            PitchSpeedTextFormatter.adjustedTitle(baseTitle: "Song", pitchSemitones: -3, rate: 1.0)
                == "Song (\(L10n.format("Key%+d", -3)))"
        )
    }

    @Test func playVideoStopsAudioAndStartsVideoService() async {
        let item = makeMediaItem(id: 1, title: "Movie", duration: 22, isVideo: true, fileName: "movie.mov")
        let url = URL(fileURLWithPath: "/tmp/movie.mov")
        let fixture = makePlayerFixture(urlsByID: [item.id: url])
        fixture.video.duration = 30

        fixture.player.play(item: item, in: [item])
        await Task.yield()
        await Task.yield()

        #expect(fixture.player.currentItem?.id == item.id)
        #expect(fixture.player.isVideoMode)
        #expect(fixture.player.showVideoArea)
        #expect(fixture.player.duration == 30)
        #expect(fixture.player.isPlaying)
        #expect(fixture.audio.suspendCallCount == 1)
        #expect(fixture.video.loadedURLs == [url])
        #expect(fixture.video.playCallCount == 1)
    }

    @Test func videoFormatLoadedCallbackUpdatesFormatInfo() async {
        let item = makeMediaItem(id: 1, title: "Movie", duration: 12, isVideo: true, fileName: "movie.mov")
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/movie.mov")])
        let formatInfo = MediaFormatInfo(
            sampleRateHz: 48_000,
            bitrateKbps: 192,
            videoFrameRateFps: 29.97,
            totalBitrateKbps: 3_200
        )

        fixture.player.play(item: item, in: [item])
        await Task.yield()
        fixture.video.onFormatLoaded?(formatInfo)

        #expect(fixture.player.formatInfo == formatInfo)
    }

    @Test func videoControlsPauseResumeSeekAndStopThroughVideoService() async {
        let item = makeMediaItem(id: 1, title: "Movie", duration: 22, isVideo: true, fileName: "movie.mov")
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/movie.mov")])

        fixture.player.play(item: item, in: [item])
        await Task.yield()
        await Task.yield()

        fixture.player.pause()
        fixture.player.resume()
        fixture.player.seek(to: -2)
        fixture.player.seek(to: 99)
        fixture.player.stop()

        #expect(fixture.video.pauseCallCount == 1)
        #expect(fixture.video.playCallCount == 2)
        #expect(fixture.video.seekTimes == [0, 22])
        #expect(fixture.video.closeCallCount == 1)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.player.queue.isEmpty)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.player.isVideoMode == false)
        #expect(fixture.player.showVideoArea == false)
    }

    @Test func clearCurrentItemStopsAudioAndResetsPlaybackState() {
        let item = makeMediaItem(id: 1, title: "One", duration: 10)
        let fixture = makePlayerFixture(urlsByID: [item.id: URL(fileURLWithPath: "/tmp/one.mp3")])
        fixture.player.play(item: item, in: [item])
        fixture.player.formatInfo = MediaFormatInfo(sampleRateHz: 44_100, bitrateKbps: 256)

        fixture.player.clearCurrentItem()

        #expect(fixture.audio.stopResets == [true] && fixture.audio.suspendCallCount == 1)
        #expect(fixture.player.currentItem == nil)
        #expect(fixture.player.queue.isEmpty)
        #expect(fixture.player.currentTime == 0)
        #expect(fixture.player.duration == 0)
        #expect(fixture.player.formatInfo == .empty)
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.player.isVideoMode == false)
        #expect(fixture.player.showVideoArea == false)
    }

    @Test func playbackCallbacksUpdateStateAndAdvanceQueue() {
        let first = makeMediaItem(id: 1, title: "One")
        let second = makeMediaItem(id: 2, title: "Two")
        let formatInfo = MediaFormatInfo(sampleRateHz: 48_000, bitrateKbps: 320)
        let fixture = makePlayerFixture(urlsByID: [
            first.id: URL(fileURLWithPath: "/tmp/one.mp3"),
            second.id: URL(fileURLWithPath: "/tmp/two.mp3")
        ])

        fixture.player.play(item: first, in: [first, second])
        fixture.audio.onFormatLoaded?(44, formatInfo)

        #expect(fixture.player.duration == 44)
        #expect(fixture.player.formatInfo == formatInfo)

        fixture.audio.onFinished?()
        #expect(fixture.player.currentItem?.id == second.id)

        fixture.audio.onError?("decode failed")
        #expect(fixture.player.errorMessage == "decode failed")
        #expect(fixture.player.isPlaying == false)
        #expect(fixture.player.formatInfo == .empty)
    }
}

@MainActor
struct LibraryServiceBoundaryTests {
    @Test func resolvedURLFallsBackToMediaDirectoryWhenBookmarkIsInvalid() {
        let item = makeMediaItem(id: 1, title: "Missing", bookmarkData: Data([0xFF]), fileName: "missing.mp3")
        let service = LibraryService()

        #expect(service.resolvedURL(for: item) == service.fallbackMediaURL(forFileName: "missing.mp3"))
    }

    @Test func mediaDirectoryURLForSourceUsesUUIDAndSourceExtension() {
        let service = LibraryService()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let sourceURL = URL(fileURLWithPath: "/tmp/source.flac")

        let url = service.mediaDirectoryURL(for: sourceURL, id: id)

        #expect(url.deletingLastPathComponent() == service.mediaDirectoryURL())
        #expect(url.lastPathComponent == "00000000-0000-0000-0000-000000000123.flac")
    }
}

private func makeMediaItem(
    id: Int,
    title: String,
    artist: String = "Unknown Artist",
    album: String = "Unknown Album",
    genre: String? = nil,
    albumArtist: String? = nil,
    composer: String? = nil,
    duration: TimeInterval = 30,
    isVideo: Bool = false,
    bookmarkData: Data = Data([1, 2, 3]),
    addedAt: Date = Date(),
    fileName: String? = nil
) -> MediaItem {
    MediaItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", id))")!,
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        albumArtist: albumArtist,
        composer: composer,
        duration: duration,
        isVideo: isVideo,
        bookmarkData: bookmarkData,
        addedAt: addedAt,
        fileName: fileName ?? "\(title).mp3"
    )
}

private func temporaryMP3URL() -> URL {
    temporaryMediaURL(extension: "mp3")
}

private func temporaryMediaURL(extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(pathExtension)
}

private func id3Tag(version: UInt8 = 3, frames: [Data]) -> Data {
    let content = frames.reduce(into: Data()) { result, frame in
        result.append(frame)
    }

    var data = Data()
    data.append(contentsOf: [0x49, 0x44, 0x33, version, 0x00, 0x00])
    data.append(id3SynchsafeData(content.count))
    data.append(content)
    return data
}

private func id3Frame(id: String, payload: Data) -> Data {
    var data = Data()
    data.append(Data(id.utf8))
    if id.count == 3 {
        data.append(id3BigEndianData(payload.count, byteCount: 3))
    } else {
        data.append(id3BigEndianData(payload.count, byteCount: 4))
        data.append(contentsOf: [0x00, 0x00])
    }
    data.append(payload)
    return data
}

private func id3ArtworkPayload(_ artwork: Data) -> Data {
    Data([0]) + Data("image/jpeg".utf8) + Data([0, 3, 0]) + artwork
}

private func id3TextPayload(_ value: String) -> Data {
    var data = Data([0x01])
    data.append(value.data(using: .utf16)!)
    return data
}

private func id3Latin1TextPayload(_ value: String) -> Data {
    var data = Data([0x00])
    data.append(value.data(using: .isoLatin1)!)
    return data
}

private func id3CommentPayload(_ value: String) -> Data {
    var data = Data([0x01])
    data.append(Data("eng".utf8))
    data.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
    data.append(value.data(using: .utf16)!)
    return data
}

private func id3LyricsPayload(_ value: String) -> Data {
    id3CommentPayload(value)
}

private func id3FramePayloads(in data: Data) throws -> [String: Data] {
    #expect(data.count >= 10)
    let version = data[3]
    let headerSize = version == 2 ? 6 : 10
    let idLength = version == 2 ? 3 : 4
    let tagSize = try id3SynchsafeInteger(data[6..<10])
    var offset = 10
    let end = 10 + tagSize
    var frames: [String: Data] = [:]

    while offset + headerSize <= end {
        let header = data[offset..<(offset + headerSize)]
        if header.allSatisfy({ $0 == 0 }) {
            break
        }

        guard let id = String(data: data[offset..<(offset + idLength)], encoding: .isoLatin1) else {
            break
        }
        let sizeRange = version == 2
            ? (offset + 3)..<(offset + 6)
            : (offset + 4)..<(offset + 8)
        let size = id3BigEndianInteger(data[sizeRange])
        let payloadStart = offset + headerSize
        let payloadEnd = payloadStart + size
        #expect(payloadEnd <= end)
        frames[id] = Data(data[payloadStart..<payloadEnd])
        offset = payloadEnd
    }

    return frames
}

private func id3TextValue(_ payload: Data?) -> String? {
    guard let payload, payload.isEmpty == false else { return nil }
    switch payload[payload.startIndex] {
    case 0x01:
        return String(data: payload.dropFirst(), encoding: .utf16)
    case 0x03:
        return String(data: payload.dropFirst(), encoding: .utf8)
    default:
        return nil
    }
}

private func id3LyricsValue(_ payload: Data?) -> String? {
    id3CommentValue(payload)
}

private func id3CommentValue(_ payload: Data?) -> String? {
    guard let payload, payload.count > 5 else { return nil }
    switch payload[payload.startIndex] {
    case 0x01:
        guard payload.count > 8 else { return "" }
        return String(data: payload.dropFirst(8), encoding: .utf16)
    case 0x03:
        return String(data: payload.dropFirst(5), encoding: .utf8)
    default:
        return nil
    }
}

private func id3SynchsafeInteger(_ bytes: Data.SubSequence) throws -> Int {
    var value = 0
    for byte in bytes {
        guard byte & 0x80 == 0 else {
            throw MediaMetadataEditError.invalidID3Tag
        }
        value = (value << 7) | Int(byte)
    }
    return value
}

private func id3SynchsafeData(_ value: Int) -> Data {
    Data([
        UInt8((value >> 21) & 0x7F),
        UInt8((value >> 14) & 0x7F),
        UInt8((value >> 7) & 0x7F),
        UInt8(value & 0x7F)
    ])
}

private func id3BigEndianInteger(_ bytes: Data.SubSequence) -> Int {
    bytes.reduce(0) { ($0 << 8) | Int($1) }
}

private func id3BigEndianData(_ value: Int, byteCount: Int) -> Data {
    var data = Data()
    for index in stride(from: byteCount - 1, through: 0, by: -1) {
        data.append(UInt8((value >> (index * 8)) & 0xFF))
    }
    return data
}

private func aiffFile(formType: String = "AIFF", chunks: [Data]) -> Data {
    let payload = chunks.reduce(into: Data(formType.utf8)) { result, chunk in
        result.append(chunk)
    }
    var data = Data("FORM".utf8)
    data.append(id3BigEndianData(payload.count, byteCount: 4))
    data.append(payload)
    return data
}

private func aiffChunk(id: String, payload: Data) -> Data {
    var data = Data(id.utf8)
    data.append(id3BigEndianData(payload.count, byteCount: 4))
    data.append(payload)
    if payload.count.isMultiple(of: 2) == false {
        data.append(0)
    }
    return data
}

private func aiffFormType(in data: Data) -> String? {
    guard data.count >= 12 else { return nil }
    return String(data: data[8..<12], encoding: .ascii)
}

private func aiffFormSize(in data: Data) -> Int? {
    guard data.count >= 8 else { return nil }
    return id3BigEndianInteger(data[4..<8])
}

private func aiffChunkPayload(id: String, in data: Data) throws -> Data? {
    try aiffChunks(in: data).first(where: { $0.id == id }).map { chunk in
        Data(data[chunk.contentRange])
    }
}

private func aiffChunks(in data: Data) throws -> [AIFFTestChunk] {
    #expect(data.count >= 12)
    #expect(String(data: data[0..<4], encoding: .ascii) == "FORM")
    let formEnd = 8 + id3BigEndianInteger(data[4..<8])
    #expect(formEnd <= data.count)

    var chunks: [AIFFTestChunk] = []
    var offset = 12
    while offset < formEnd {
        #expect(offset + 8 <= formEnd)
        let id = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
        let size = id3BigEndianInteger(data[(offset + 4)..<(offset + 8)])
        let contentStart = offset + 8
        let contentEnd = contentStart + size
        let totalEnd = contentEnd + (size.isMultiple(of: 2) ? 0 : 1)
        #expect(contentEnd <= formEnd)
        #expect(totalEnd <= formEnd)
        chunks.append(AIFFTestChunk(id: id, totalRange: offset..<totalEnd, contentRange: contentStart..<contentEnd))
        offset = totalEnd
    }

    return chunks
}

private struct AIFFTestChunk {
    let id: String
    let totalRange: Range<Int>
    let contentRange: Range<Int>
}

private func mp4TestBox(type: String, payload: Data) -> Data {
    mp4TestBox(type: Array(type.utf8), payload: payload)
}

private func mp4TestBox(type: [UInt8], payload: Data) -> Data {
    var data = Data()
    var size = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
    data.append(contentsOf: type)
    data.append(payload)
    return data
}

private func mp4MetadataItem(type: [UInt8], value: String) -> Data {
    var payload = Data([0, 0, 0, 1, 0, 0, 0, 0])
    payload.append(Data(value.utf8))
    return mp4TestBox(type: type, payload: mp4TestBox(type: "data", payload: payload))
}

private func mp4ArtworkItem(_ artwork: Data) -> Data {
    var payload = Data([0, 0, 0, 13, 0, 0, 0, 0])
    payload.append(artwork)
    return mp4TestBox(type: "covr", payload: mp4TestBox(type: "data", payload: payload))
}

private func mp4StcoBox(offset: UInt32) -> Data {
    var payload = Data([0, 0, 0, 0, 0, 0, 0, 1])
    payload.append(mp4UInt32Data(offset))
    return mp4TestBox(type: "stco", payload: payload)
}

private func mp4MetadataValues(in data: Data) throws -> [String: String] {
    guard let moovBox = try mp4Boxes(in: 0..<data.count, data: data).first(where: { $0.type == "moov" }),
          let udtaBox = try mp4Boxes(in: moovBox.contentRange, data: data).first(where: { $0.type == "udta" }),
          let metaBox = try mp4Boxes(in: udtaBox.contentRange, data: data).first(where: { $0.type == "meta" }),
          let ilstBox = try mp4Boxes(
              in: (metaBox.contentRange.lowerBound + 4)..<metaBox.contentRange.upperBound, data: data
          ).first(where: { $0.type == "ilst" })
    else {
        return [:]
    }

    var values: [String: String] = [:]
    for itemBox in try mp4Boxes(in: ilstBox.contentRange, data: data) {
        if itemBox.type == "covr" {
            if let dataBox = try mp4Boxes(in: itemBox.contentRange, data: data).first(where: { $0.type == "data" }),
               dataBox.contentRange.count >= 8 {
                values["covrData"] = Data(data[(dataBox.contentRange.lowerBound + 8)..<dataBox.contentRange.upperBound])
                    .base64EncodedString()
            } else {
                values["covrData"] = Data(data[itemBox.contentRange]).base64EncodedString()
            }
            continue
        }
        guard let dataBox = try mp4Boxes(in: itemBox.contentRange, data: data).first(where: { $0.type == "data" })
        else {
            continue
        }
        let payloadStart = dataBox.contentRange.lowerBound + 8
        guard payloadStart <= dataBox.contentRange.upperBound else { continue }
        if itemBox.type == "trkn" || itemBox.type == "disk" {
            values[itemBox.type] = mp4NumberPairString(in: data, at: payloadStart)
            continue
        }
        if itemBox.type == "cpil" {
            values[itemBox.type] = data[payloadStart..<dataBox.contentRange.upperBound]
                .contains(where: { $0 != 0 }) ? "1" : "0"
            continue
        }
        if let value = String(data: data[payloadStart..<dataBox.contentRange.upperBound], encoding: .utf8) {
            values[itemBox.type] = value
        }
    }
    return values
}

private func mp4NumberPairString(in data: Data, at offset: Int) -> String? {
    guard offset + 6 <= data.count else { return nil }
    let current = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
    let total = UInt16(data[offset + 4]) << 8 | UInt16(data[offset + 5])
    guard current > 0 else { return nil }
    return total > 0 ? "\(current)/\(total)" : "\(current)"
}

private func mp4FirstStcoOffset(in data: Data) throws -> UInt32? {
    try mp4FirstBox(ofType: "stco", in: 0..<data.count, data: data).map { box in
        mp4UInt32(in: data, at: box.contentRange.lowerBound + 8)
    }
}

private func mp4MdatPayloadOffset(in data: Data) throws -> Int {
    guard let mdatBox = try mp4Boxes(in: 0..<data.count, data: data).first(where: { $0.type == "mdat" }) else {
        return -1
    }
    return mdatBox.contentRange.lowerBound
}

private func mp4FirstBox(ofType type: String, in range: Range<Int>, data: Data) throws -> MP4TestBox? {
    for box in try mp4Boxes(in: range, data: data) {
        if box.type == type {
            return box
        }

        let childRange: Range<Int>?
        if box.type == "meta", box.contentRange.count >= 4 {
            childRange = (box.contentRange.lowerBound + 4)..<box.contentRange.upperBound
        } else if ["moov", "trak", "mdia", "minf", "stbl", "udta"].contains(box.type) {
            childRange = box.contentRange
        } else {
            childRange = nil
        }

        if let childRange, let found = try mp4FirstBox(ofType: type, in: childRange, data: data) {
            return found
        }
    }
    return nil
}

private func mp4Boxes(in range: Range<Int>, data: Data) throws -> [MP4TestBox] {
    var boxes: [MP4TestBox] = []
    var offset = range.lowerBound

    while offset + 8 <= range.upperBound {
        let size = Int(mp4UInt32(in: data, at: offset))
        guard size >= 8, offset + size <= range.upperBound else {
            break
        }
        let rawType = Data(data[(offset + 4)..<(offset + 8)])
        let type = mp4TypeString(rawType)
        boxes.append(MP4TestBox(
            type: type, totalRange: offset..<(offset + size), contentRange: (offset + 8)..<(offset + size)
        ))
        offset += size
    }

    return boxes
}

private func mp4TypeString(_ data: Data) -> String {
    if data.count == 4, data[data.startIndex] == 0xA9 {
        let suffix = String(data: data.dropFirst(), encoding: .utf8) ?? ""
        return "©" + suffix
    }
    return String(data: data, encoding: .utf8) ?? data.map { String(format: "%02X", $0) }.joined()
}

private func mp4UInt32(in data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}

private func mp4UInt32Data(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ])
}

private struct MP4TestBox {
    let type: String
    let totalRange: Range<Int>
    let contentRange: Range<Int>
}

@MainActor
func makePlayerFixture(
    urlsByID: [UUID: URL] = [:],
    equalizer: EqualizerSettings = .flat,
    equalizerDefaults: UserDefaults = .standard,
    startsClock: Bool = false, musicAnalysis: MusicAnalysisController? = nil
) -> (
    player: PlayerViewModel,
    audio: FakeAudioEngine,
    video: FakeVideoService,
    resolver: FakeMediaURLResolver
) {
    let resolver = FakeMediaURLResolver(urlsByID: urlsByID)
    let audio = FakeAudioEngine()
    let video = FakeVideoService()
    let player = PlayerViewModel(
        libraryService: resolver,
        audioEngine: audio,
        videoService: video,
        startsClock: startsClock,
        equalizer: equalizer,
        equalizerDefaults: equalizerDefaults, musicAnalysis: musicAnalysis ?? MusicAnalysisController()
    )
    return (player, audio, video, resolver)
}

@MainActor
final class FakeMediaURLResolver: MediaURLResolving {
    var urlsByID: [UUID: URL]
    var resolvedItemIDs: [UUID] = []

    init(urlsByID: [UUID: URL]) {
        self.urlsByID = urlsByID
    }

    func resolvedURL(for item: MediaItem) -> URL? {
        resolvedItemIDs.append(item.id)
        return urlsByID[item.id]
    }
}

@MainActor
final class FakeAudioEngine: AudioPlaybackControlling {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var onFinished: (@MainActor () -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onFormatLoaded: (@MainActor (_ duration: TimeInterval, _ formatInfo: MediaFormatInfo) -> Void)?

    var loadedURLs: [URL] = []
    var playCallCount = 0
    var pauseCallCount = 0
    var stopResets: [Bool] = []
    var suspendCallCount = 0
    var seekRequests: [(time: TimeInterval, autoPlay: Bool)] = []
    var resetEngineCallCount = 0
    var volumes: [Float] = []
    var pitchCents: [Float] = []
    var playbackRates: [Float] = []
    var volumeNormalizationValues: [Bool] = []
    var equalizerValues: [EqualizerSettings] = []

    func setVolume(_ volume: Float) {
        volumes.append(volume)
    }

    func setPitchCents(_ cents: Float) {
        pitchCents.append(cents)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRates.append(rate)
    }

    func setVolumeNormalizationEnabled(_ enabled: Bool) {
        volumeNormalizationValues.append(enabled)
    }

    func setEqualizer(_ settings: EqualizerSettings) {
        equalizerValues.append(settings)
    }

    func load(url: URL) {
        loadedURLs.append(url)
    }

    func play() {
        playCallCount += 1
    }

    func pause() {
        pauseCallCount += 1
    }

    func stop(reset: Bool) {
        stopResets.append(reset)
    }

    func suspend() {
        suspendCallCount += 1
    }

    func seek(to time: TimeInterval, autoPlay: Bool) {
        seekRequests.append((time, autoPlay))
    }

    func resetEngine() {
        resetEngineCallCount += 1
    }
}

@MainActor
final class FakeVideoService: VideoPlaybackControlling {
    let player = AVPlayer()
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var onFinished: (() -> Void)?
    var onFormatLoaded: (@MainActor (MediaFormatInfo) -> Void)?

    var loadedURLs: [URL] = []
    var playCallCount = 0
    var pauseCallCount = 0
    var stopCallCount = 0
    var closeCallCount = 0
    var seekTimes: [TimeInterval] = []
    var volumes: [Float] = []
    var equalizerValues: [EqualizerSettings] = []

    func load(url: URL) async {
        loadedURLs.append(url)
    }

    func play() {
        playCallCount += 1
    }

    func pause() {
        pauseCallCount += 1
    }

    func setVolume(_ volume: Float) {
        volumes.append(volume)
    }

    func setEqualizer(_ settings: EqualizerSettings) {
        equalizerValues.append(settings)
    }

    func stop() {
        stopCallCount += 1
    }

    func close() {
        closeCallCount += 1
    }

    func seek(to time: TimeInterval) {
        seekTimes.append(time)
    }
}

private extension Int {
    var toUnitColorChannel: Double {
        Double(self) / 255.0
    }
}

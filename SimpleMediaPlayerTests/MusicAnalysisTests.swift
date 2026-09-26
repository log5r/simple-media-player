import Foundation
import Testing
@testable import SimpleMediaPlayer

struct MusicAnalysisTests {
    @Test func keyRangesRespectStructureAndCoverGapsAndLongSections() {
        let analysis = MusicAnalysis(duration: 100, sections: [
            .init(start: 10, end: 20), .init(start: 20, end: 90),
            .init(start: .nan, end: .infinity)
        ])
        let ranges = analysis.keyAnalysisRanges()
        #expect(ranges.first?.start == 0)
        #expect(ranges.last?.end == 100)
        #expect(ranges.contains(.init(start: 10, end: 20)))
        #expect(ranges.allSatisfy { $0.end > $0.start && $0.end - $0.start <= 30 })
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.end == $1.start })
        #expect(MusicAnalysis(duration: 20).keyAnalysisRanges().isEmpty)
        #expect(MusicAnalysis(duration: .nan).keyAnalysisRanges().isEmpty)
    }

    @Test func localKeysReplaceOnlyDetectedSpansAndSurviveCaching() throws {
        var analysis = MusicAnalysis(duration: 60, keys: [
            .init(interval: .init(start: 0, end: 60), pitchClass: 0, name: "C", isMinor: false)
        ])
        analysis.applyKeyExcerpt([
            .init(interval: .init(start: 10, end: 25), pitchClass: 4, name: "E", isMinor: true),
            .init(interval: .init(start: 28, end: 45), pitchClass: 7, name: "G", isMinor: false),
            .init(interval: .init(start: .nan, end: 30), pitchClass: 0, name: "C", isMinor: false)
        ], range: .init(start: 20, end: 40))
        let decoded = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(analysis))
        #expect(decoded.keyLabel(at: 19, transposition: 0) == "C")
        #expect(decoded.keyLabel(at: 20, transposition: 0) == "Em")
        #expect(decoded.keyLabel(at: 25, transposition: 0) == "C")
        #expect(decoded.keyLabel(at: 28, transposition: 0) == "G")
        #expect(decoded.keyLabel(at: 40, transposition: 0) == "C")
        #expect(zip(decoded.keys, decoded.keys.dropFirst()).allSatisfy { $0.interval.end <= $1.interval.start })
    }

    @Test func rhythmRangesCoverTrackWithOverlappingContextAndSkipShortSongs() {
        let analysis = MusicAnalysis(duration: 83, sections: [
            .init(start: 0, end: 5), .init(start: 5, end: 18), .init(start: 18, end: 83)
        ])
        let ranges = analysis.rhythmAnalysisRanges()
        #expect(ranges.count == 3)
        #expect(ranges.first?.start == 0)
        #expect(ranges.first?.end == 30)
        #expect(ranges.last?.end == 83)
        for range in ranges {
            let context = analysis.rhythmAnalysisContext(for: range)
            #expect(context.start <= range.start)
            #expect(context.end >= range.end)
            #expect(context.end - context.start == 60)
        }
        #expect(MusicAnalysis(duration: 7).rhythmAnalysisRanges().isEmpty)
        #expect(MusicAnalysis(duration: .nan).rhythmAnalysisRanges().isEmpty)
        #expect(MusicAnalysis(duration: 60).rhythmAnalysisRanges().isEmpty)
    }

    @Test func independentRhythmCorrectsHalfTimeWithoutMixingBoundaryIntervals() throws {
        var analysis = MusicAnalysis(duration: 40, beats: (0..<50).map { Double($0) * 0.8 },
                                     bars: (0..<13).map { Double($0) * 3.2 }, bpm: 75)
        analysis.applyRhythmExcerpts([.init(range: .init(start: 16, end: 32),
                               context: .init(start: 16, end: 32),
                               beats: (0..<40).map { 16.1 + Double($0) * 0.4 },
                               bars: [16.1, 17.7, 19.3, 20.9, 22.5, 24.1, 25.7, 27.3, 28.9, 30.5])])
        let restored = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(analysis))
        let tempo = restored.tempoByBeat()
        #expect(restored.displayedBPM(at: 8, tempoByBeat: tempo, rate: 1) == 75)
        #expect(restored.displayedBPM(at: 16.1, tempoByBeat: tempo, rate: 1) == 150)
        #expect(restored.displayedBPM(at: 20, tempoByBeat: tempo, rate: 1) == 150)
        #expect(restored.displayedBPM(at: 35, tempoByBeat: tempo, rate: 1) == 75)
        #expect(restored.beatPosition(at: 16.5)?.count == 4)
        #expect(restored.beatPosition(at: 18.1)?.count == 4)
        #expect(restored.beatPosition(at: 18.2)?.index == 1)
    }

    @Test func emptyExcerptRetainsOriginalRhythmAndLegacyCachesDecode() throws {
        var analysis = MusicAnalysis(duration: 8, beats: [0, 0.8, 1.6], bars: [0], bpm: 75)
        analysis.applyRhythmExcerpts([.init(range: .init(start: 0, end: 8),
            context: .init(start: 0, end: 8), beats: [.nan, 8, 9], bars: [])])
        #expect(analysis.beats == [0, 0.8, 1.6])
        #expect(analysis.bars == [0])
        #expect(analysis.rhythmRegions == nil)
        let legacy = Data(#"{"duration":8,"sections":[],"pace":[],"keys":[],"beats":[0,0.8],"bars":[0],"bpm":75}"#.utf8)
        #expect(try JSONDecoder().decode(MusicAnalysis.self, from: legacy).rhythmRegions == nil)
    }

    @Test func overlappingRhythmPreservesTempoAndMeterChangesWithoutDuplicateBeats() throws {
        let beats = stride(from: 0.0, to: 24.0, by: 0.5).map { $0 }
            + stride(from: 24.0, to: 90.0, by: 0.25).map { $0 }
        let bars = stride(from: 0.0, to: 24.0, by: 2.0).map { $0 }
            + stride(from: 24.0, to: 33.0, by: 0.75).map { $0 }
            + stride(from: 33.0, to: 90.0, by: 1.75).map { $0 }
        var analysis = MusicAnalysis(duration: 90, bpm: 60)
        let excerpts = [(0.0, 30.0, 0.0, 60.0, 0.0),
                        (30.0, 60.0, 15.0, 75.0, 0.02),
                        (60.0, 90.0, 30.0, 90.0, -0.015)].map { start, end, low, high, shift in
            MusicAnalysis.RhythmExcerpt(range: .init(start: start, end: end),
                context: .init(start: low, end: high),
                beats: beats.filter { $0 >= low && $0 < high }.map { $0 + shift },
                bars: bars.filter { $0 >= low && $0 < high }.map { $0 + shift + 0.005 })
        }
        analysis.applyRhythmExcerpts(excerpts)
        let restored = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(analysis))
        #expect(restored.beats.count == beats.count)
        #expect(restored.bars.count == bars.count)
        #expect(restored.uncertainRhythmRanges?.isEmpty == true)
        #expect(restored.beatPosition(at: 20)?.count == 4)
        #expect(restored.beatPosition(at: 29.9)?.count == 3)
        #expect(restored.beatPosition(at: 30.1)?.count == 3)
        #expect(restored.beatPosition(at: 33.1)?.count == 7)
        #expect(restored.beatPosition(at: 59.1)?.count == 7)
        #expect(restored.beatPosition(at: 60.1)?.count == 7)
        let tempo = restored.tempoByBeat()
        #expect(restored.displayedBPM(at: 20, tempoByBeat: tempo, rate: 1) == 120)
        #expect(restored.displayedBPM(at: 30.1, tempoByBeat: tempo, rate: 1) == 240)
        #expect(restored.displayedBPM(at: 60.1, tempoByBeat: tempo, rate: 1) == 240)
    }

    @Test func tempoAndMeterCanChangeExactlyAtTheMatchedDownbeat() {
        let beats = stride(from: 0.0, to: 30.0, by: 0.5).map { $0 }
            + stride(from: 30.0, to: 61.0, by: 0.25).map { $0 }
        let bars = stride(from: 0.0, to: 30.0, by: 2.0).map { $0 }
            + stride(from: 30.0, to: 61.0, by: 1.75).map { $0 }
        var analysis = MusicAnalysis(duration: 61)
        analysis.applyRhythmExcerpts(analysis.rhythmAnalysisRanges().map { range in
            let context = analysis.rhythmAnalysisContext(for: range)
            return .init(range: range, context: context,
                         beats: beats.filter { context.contains($0) },
                         bars: bars.filter { context.contains($0) })
        })
        #expect(analysis.beats == beats)
        #expect(analysis.bars == bars)
        #expect(analysis.beatPosition(at: 29.9)?.count == 4)
        #expect(analysis.beatPosition(at: 30)?.count == 7)
        #expect(analysis.beatPosition(at: 30)?.index == 0)
        let tempo = analysis.tempoByBeat()
        #expect(analysis.displayedBPM(at: 29.9, tempoByBeat: tempo, rate: 1) == 120)
        #expect(analysis.displayedBPM(at: 30, tempoByBeat: tempo, rate: 1) == 240)
        #expect(analysis.uncertainRhythmRanges?.isEmpty == true)
    }

    @Test func missingExcerptDoesNotDiscardSuccessfulLocalAnalyses() throws {
        let originalBeats = stride(from: 0.0, to: 90.0, by: 1).map { $0 }
        var analysis = MusicAnalysis(duration: 90, beats: originalBeats,
                                     bars: stride(from: 0.0, to: 90.0, by: 4).map { $0 })
        analysis.applyRhythmExcerpts([
            .init(range: .init(start: 0, end: 30), context: .init(start: 0, end: 60),
                  beats: stride(from: 0.0, to: 60.0, by: 0.5).map { $0 },
                  bars: stride(from: 0.0, to: 60.0, by: 2).map { $0 }),
            .init(range: .init(start: 30, end: 60), context: .init(start: 15, end: 75),
                  beats: [.nan, .infinity], bars: []),
            .init(range: .init(start: 60, end: 90), context: .init(start: 30, end: 90),
                  beats: stride(from: 30.0, to: 90.0, by: 0.25).map { $0 },
                  bars: stride(from: 30.0, to: 90.0, by: 0.75).map { $0 })
        ])
        let restored = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(analysis))
        let tempo = restored.tempoByBeat()
        #expect(restored.displayedBPM(at: 10, tempoByBeat: tempo, rate: 1) == 120)
        #expect(restored.displayedBPM(at: 45, tempoByBeat: tempo, rate: 1) == 60)
        #expect(restored.displayedBPM(at: 70, tempoByBeat: tempo, rate: 1) == 240)
        #expect(restored.uncertainRhythmRanges?.count == 2)
        #expect(restored.beatPosition(at: 29.9) == nil)
        #expect(restored.beatPosition(at: 59.9) == nil)
    }

    @Test func overlapAvoidsAnExtraBeatAtTheNominalBoundary() {
        let beats = stride(from: 0.0, to: 90.0, by: 0.5).map { $0 }
        let bars = stride(from: 0.0, to: 90.0, by: 2.0).map { $0 }
        var analysis = MusicAnalysis(duration: 90)
        analysis.applyRhythmExcerpts([
            .init(range: .init(start: 0, end: 30), context: .init(start: 0, end: 60),
                  beats: beats.filter { $0 < 60 }, bars: bars.filter { $0 < 60 }),
            .init(range: .init(start: 30, end: 90), context: .init(start: 15, end: 90),
                  beats: beats.filter { $0 >= 15 } + [30.1], bars: bars.filter { $0 >= 15 })
        ])
        // The common downbeat at 32 avoids the inconsistent neighborhood around 30.
        #expect(analysis.beats == beats)
        #expect(analysis.bars == bars)
        #expect(analysis.uncertainRhythmRanges?.isEmpty == true)
        #expect(analysis.beatPosition(at: 30.2)?.count == 4)
    }

    @Test func disagreementOnDownbeatsDoesNotInventASixBeatBar() {
        let beats = stride(from: 0.0, to: 90.0, by: 0.5).map { $0 }
        var analysis = MusicAnalysis(duration: 90)
        analysis.applyRhythmExcerpts([
            .init(range: .init(start: 0, end: 30), context: .init(start: 0, end: 60),
                  beats: beats.filter { $0 < 60 }, bars: stride(from: 0.0, to: 60.0, by: 2).map { $0 }),
            .init(range: .init(start: 30, end: 90), context: .init(start: 15, end: 90),
                  beats: beats.filter { $0 >= 15 }, bars: stride(from: 15.0, to: 90.0, by: 2).map { $0 })
        ])
        #expect(analysis.beats == beats)
        #expect(analysis.beatPosition(at: 29.75) == nil)
        #expect(analysis.beatPosition(at: 31.1)?.count == 4)
        #expect(analysis.beatPosition(at: 31.6)?.index == 1)
    }

    @Test func incompatibleBeatPhaseKeepsLocalTempoAndMarksTheSeamUncertain() {
        var analysis = MusicAnalysis(duration: 90)
        analysis.applyRhythmExcerpts([
            .init(range: .init(start: 0, end: 30), context: .init(start: 0, end: 60),
                  beats: stride(from: 0.0, to: 60.0, by: 0.5).map { $0 },
                  bars: stride(from: 0.0, to: 60.0, by: 2).map { $0 }),
            .init(range: .init(start: 30, end: 90), context: .init(start: 15, end: 90),
                  beats: stride(from: 15.25, to: 90.0, by: 0.5).map { $0 },
                  bars: stride(from: 15.25, to: 90.0, by: 2).map { $0 })
        ])
        #expect(analysis.beatPosition(at: 29.75) == nil)
        #expect(analysis.beatPosition(at: 32)?.count == 4)
        #expect(analysis.beats.contains(30.25))
        #expect(analysis.displayedBPM(at: 30.25, tempoByBeat: analysis.tempoByBeat(), rate: 1) == 120)
    }

    @Test func slowIntroDoesNotOverrideFasterRemainderEvenAfterCachingAndSeeking() throws {
        let intro = (0..<16).map { Double($0) * 0.8 }
        let remainder = (0..<128).map { 12.8 + Double($0) * 0.4 }
        let original = MusicAnalysis(duration: 64, beats: intro + remainder, bpm: 75)
        let analysis = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(original))
        let tempo = analysis.tempoByBeat()

        #expect(analysis.displayedBPM(at: 8, tempoByBeat: tempo, rate: 1) == 75)
        #expect(analysis.displayedBPM(at: 20, tempoByBeat: tempo, rate: 1) == 150)
        #expect(analysis.displayedBPM(at: 60, tempoByBeat: tempo, rate: 1) == 150)
        #expect(analysis.displayedBPM(at: 8, tempoByBeat: tempo, rate: 1) == 75)
        #expect(analysis.displayedBPM(at: 20, tempoByBeat: tempo, rate: 0.5) == 75)
    }

    @Test func localTempoFollowsChangesOnlyAtBeatsAndSupportsSeekingAndSpeed() {
        let analysis = MusicAnalysis(duration: 4, beats: [0, 0.5, 1, 1.5, 2, 2.25, 2.5, 2.75, 3],
                                     bars: [0, 1.5, 2], bpm: 120)
        let tempo = analysis.tempoByBeat()
        #expect(analysis.displayedBPM(at: 2.249, tempoByBeat: tempo, rate: 1) == 120)
        #expect(analysis.displayedBPM(at: 2.25, tempoByBeat: tempo, rate: 1) == 137)
        #expect(analysis.displayedBPM(at: 2.5, tempoByBeat: tempo, rate: 1) == 160)
        #expect(analysis.displayedBPM(at: 2.75, tempoByBeat: tempo, rate: 1) == 192)
        #expect(analysis.displayedBPM(at: 3, tempoByBeat: tempo, rate: 1) == 240)
        #expect(analysis.displayedBPM(at: 3, tempoByBeat: tempo, rate: 0.5) == 120)
        #expect(analysis.displayedBPM(at: 1, tempoByBeat: tempo, rate: 1) == 120)
        #expect(analysis.displayedBPM(at: 4, tempoByBeat: tempo, rate: 1) == 240)
    }

    @Test func localTempoSmoothsTimingJitterUsingIntervalsRatherThanAveragingBPM() {
        let analysis = MusicAnalysis(duration: 3, beats: [0, 0.45, 1, 1.45, 2])
        let tempo = analysis.tempoByBeat()
        #expect(analysis.displayedBPM(at: 2, tempoByBeat: tempo, rate: 1) == 120)
    }

    @Test func localTempoFallsBackUntilTwoBeatsAreAvailable() {
        let analysis = MusicAnalysis(duration: 8, beats: [1, 1.5], bpm: 100)
        let tempo = analysis.tempoByBeat()
        #expect(analysis.displayedBPM(at: 0, tempoByBeat: tempo, rate: 1) == 100)
        #expect(analysis.displayedBPM(at: 1, tempoByBeat: tempo, rate: 1) == 100)
        #expect(analysis.displayedBPM(at: 1.5, tempoByBeat: tempo, rate: 1) == 120)
        #expect(MusicAnalysis(duration: 8, beats: [1]).tempoByBeat() == [nil])
        #expect(MusicAnalysis(duration: 8).tempoByBeat().isEmpty)
        #expect(MusicAnalysis(duration: 8).displayedBPM(at: 1, rate: 1) == nil)
        #expect(analysis.displayedBPM(at: .nan, tempoByBeat: tempo, rate: 1) == nil)
    }

    @Test func localTempoResetsItsWindowAfterInvalidIntervals() {
        let analysis = MusicAnalysis(duration: 8, beats: [0, 0.5, 0.5, 0.75, .infinity])
        #expect(analysis.tempoByBeat() == [nil, 120, nil, 240, nil])
    }

    @Test func cachedBeatDataCanRebuildTempoWithoutReanalyzingAudio() throws {
        let original = MusicAnalysis(duration: 4, beats: [0, 0.5, 1, 1.5, 2], bpm: 100)
        let decoded = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(original))
        #expect(decoded.displayedBPM(at: 2, tempoByBeat: decoded.tempoByBeat(), rate: 1) == 120)
    }

    @Test func beatLookupHandlesPickupSilenceAndEmptyBars() {
        let analysis = MusicAnalysis(duration: 10, beats: [0.5, 1, 4, 4.5, 6], bars: [0, 2, 4, 6])
        #expect(analysis.beatPosition(at: 0) == nil)
        #expect(analysis.beatPosition(at: 0.5) == .init(count: 2, index: 0))
        #expect(analysis.beatPosition(at: 2) == nil)
        #expect(analysis.beatPosition(at: 4) == .init(count: 2, index: 0))
        #expect(analysis.beatPosition(at: 6) == .init(count: 1, index: 0))
    }

    @Test func overviewNormalizesOnceAndPreservesGapsWithUnsortedInput() {
        let analysis = MusicAnalysis(duration: 8, pace: [
            .init(interval: .init(start: 4, end: 6), value: 100),
            .init(interval: .init(start: 0, end: 2), value: 50),
            .init(interval: .init(start: 6, end: 8), value: .nan)
        ])
        #expect(analysis.paceOverview(sampleCount: 8) == [0.5, 0.5, nil, nil, 1, 1, nil, nil])
        #expect(analysis.paceOverview(sampleCount: 0).isEmpty)
        #expect(MusicAnalysis(duration: 8).paceOverview().isEmpty)
    }

    @Test func beatsFollowDetectedBarsIncludingMeterChangesAndSeeking() {
        let analysis = MusicAnalysis(duration: 8, beats: [0, 1, 2, 3, 4, 5, 6, 7], bars: [0, 3, 7])
        #expect(analysis.beatPosition(at: 0) == .init(count: 3, index: 0))
        #expect(analysis.beatPosition(at: 2.9) == .init(count: 3, index: 2))
        #expect(analysis.beatPosition(at: 3) == .init(count: 4, index: 0))
        #expect(analysis.beatPosition(at: 6.9) == .init(count: 4, index: 3))
        #expect(analysis.beatPosition(at: 1) == .init(count: 3, index: 1))
        #expect(analysis.beatPosition(at: 7) == .init(count: 1, index: 0))
        #expect(analysis.beatPosition(at: 8) == nil)
        #expect(analysis.beatPosition(at: -.infinity) == nil)
        #expect(MusicAnalysis(duration: 8).beatPosition(at: 1) == nil)
    }

    @Test func keyChangesAtBoundariesAndTransposesAcrossOctaves() {
        let analysis = MusicAnalysis(duration: 8, keys: [
            .init(interval: .init(start: 0, end: 4), pitchClass: 1, name: "D♭", isMinor: false),
            .init(interval: .init(start: 4, end: 8), pitchClass: 4, name: "E", isMinor: true)
        ])
        #expect(analysis.keyLabel(at: 0, transposition: 0) == "D♭")
        #expect(analysis.keyLabel(at: 4, transposition: 0) == "Em")
        #expect(analysis.keyLabel(at: 0, transposition: -2) == "B")
        #expect(analysis.keyLabel(at: 4, transposition: 10) == "Dm")
        #expect(analysis.keyLabel(at: 8, transposition: 0) == nil)
    }

    @Test func tempoReflectsSpeedAndRejectsMissingOrNonfiniteValues() {
        #expect(MusicAnalysis(duration: 8, bpm: 120).displayedBPM(rate: 1.5) == 180)
        #expect(MusicAnalysis(duration: 8, bpm: 120).displayedBPM(rate: 0.5) == 60)
        #expect(MusicAnalysis(duration: 8, bpm: .nan).displayedBPM(rate: 1) == nil)
        #expect(MusicAnalysis(duration: 8).displayedBPM(rate: 1) == nil)
    }

    @Test func paceUsesRelativeEnergyAndLeavesUnanalyzedRangesEmpty() throws {
        let analysis = MusicAnalysis(duration: 8, pace: [
            .init(interval: .init(start: 0, end: 2), value: 50),
            .init(interval: .init(start: 2, end: 4), value: 100)
        ])
        #expect(analysis.paceOverview(sampleCount: 8)[1] == 0.5)
        #expect(analysis.paceOverview(sampleCount: 8)[2] == 1)
        #expect(analysis.paceOverview(sampleCount: 8)[6] == nil)
        let decoded = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(analysis))
        #expect(decoded.paceOverview(sampleCount: 8)[1] == 0.5)
    }
}

@MainActor
struct MusicAnalysisControllerTests {
    @Test func publishesSettledFeaturesBeforeLocalRhythmFinishes() async {
        guard #available(macOS 27, iOS 27, *) else { return }
        let gate = AnalysisGate()
        let controller = MusicAnalysisController(analyzeWithProgress: { url, progress in
            await progress(MusicAnalysis(duration: 64, sections: [.init(start: 0, end: 16)],
                pace: [.init(interval: .init(start: 0, end: 64), value: 50)]))
            return await gate.analyze(url)
        })
        let task = controller.load(url: URL(fileURLWithPath: "/progress"))
        await gate.waitForRequest("progress")
        #expect(controller.status == .analyzing)
        #expect(controller.result?.sections.count == 1)
        #expect(!controller.paceLevels.isEmpty)
        #expect(controller.result?.bpm == nil)
        #expect(controller.tempoByBeat.isEmpty)
        await gate.finish("progress", bpm: 148)
        await task?.value
        #expect(controller.status == .ready)
        #expect(controller.result?.bpm == 148)
    }

    @Test func lateProgressCannotReplaceAnotherTrackOrReappearAfterReset() async {
        guard #available(macOS 27, iOS 27, *) else { return }
        let gate = AnalysisGate()
        let controller = MusicAnalysisController(analyzeWithProgress: { url, progress in
            let result = await gate.analyze(url)
            await progress(MusicAnalysis(duration: 90, bpm: 74))
            return result
        })
        let first = controller.load(url: URL(fileURLWithPath: "/first"))
        await gate.waitForRequest("first")
        let second = controller.load(url: URL(fileURLWithPath: "/second"))
        await gate.waitForRequest("second")
        await gate.finish("second", bpm: 148)
        await second?.value
        await gate.finish("first", bpm: 74)
        await first?.value
        #expect(controller.result?.bpm == 148)
        #expect(controller.status == .ready)
        let third = controller.load(url: URL(fileURLWithPath: "/third"))
        await gate.waitForRequest("third")
        controller.reset()
        await gate.finish("third", bpm: 90)
        await third?.value
        #expect(controller.result == nil)
        #expect(controller.status == .idle)
    }

    @Test func preparesLocalTempoAndClearsItOnReset() async {
        guard #available(macOS 27, iOS 27, *) else { return }
        let controller = MusicAnalysisController { _ in
            MusicAnalysis(duration: 4, beats: [0, 0.5, 1, 1.5, 2])
        }
        await controller.load(url: URL(fileURLWithPath: "/tempo"))?.value
        #expect(controller.tempoByBeat == [nil, 120, 120, 120, 120])
        controller.reset()
        #expect(controller.tempoByBeat.isEmpty)
    }

    @Test func switchingTracksDiscardsLateResults() async {
        guard #available(macOS 27, iOS 27, *) else { return }
        let gate = AnalysisGate()
        let controller = MusicAnalysisController { url in await gate.analyze(url) }
        let first = controller.load(url: URL(fileURLWithPath: "/first"))
        await gate.waitForRequest("first")
        let second = controller.load(url: URL(fileURLWithPath: "/second"))
        await gate.waitForRequest("second")
        #expect(controller.result == nil)
        #expect(controller.status == .analyzing)
        await gate.finish("second", bpm: 130)
        await second?.value
        await gate.finish("first", bpm: 90)
        await first?.value
        #expect(controller.result?.bpm == 130)
        #expect(controller.status == .ready)
    }

    @Test func resetPreventsInFlightAnalysisFromReappearing() async {
        guard #available(macOS 27, iOS 27, *) else { return }
        let gate = AnalysisGate()
        let controller = MusicAnalysisController { url in await gate.analyze(url) }
        let task = controller.load(url: URL(fileURLWithPath: "/first"))
        await gate.waitForRequest("first")
        controller.reset()
        await gate.finish("first", bpm: 90)
        await task?.value
        #expect(controller.result == nil)
        #expect(controller.status == .idle)
    }

    @Test func failureProducesFallbackState() async {
        guard #available(macOS 27, iOS 27, *) else { return }
        let controller = MusicAnalysisController { _ in throw CocoaError(.fileReadUnknown) }
        await controller.load(url: URL(fileURLWithPath: "/missing"))?.value
        #expect(controller.result == nil)
        #expect(controller.status == .failed)
    }
}

private actor AnalysisGate {
    var requests: [String: CheckedContinuation<MusicAnalysis, Never>] = [:]
    var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func analyze(_ url: URL) async -> MusicAnalysis {
        await withCheckedContinuation { continuation in
            requests[url.lastPathComponent] = continuation
            waiters.removeValue(forKey: url.lastPathComponent)?.resume()
        }
    }

    func waitForRequest(_ name: String) async {
        if requests[name] != nil { return }
        await withCheckedContinuation { waiters[name] = $0 }
    }

    func finish(_ name: String, bpm: Double) {
        requests.removeValue(forKey: name)?.resume(returning: MusicAnalysis(duration: 8, bpm: bpm))
    }
}

struct MusicAnalysisServiceTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func concurrentRefinementMatchesSerialResults(keyReleasedFirst: Bool) async throws {
        let service = MusicAnalysisService()
        let original = MusicAnalysis(duration: 90, sections: [.init(start: 0, end: 45)],
            keys: [.init(interval: .init(start: 0, end: 90), pitchClass: 0, name: "C", isMinor: false)],
            beats: [0, 1, 2], bars: [0], bpm: 60)
        let key: @Sendable (MusicAnalysis.Interval) async throws -> [MusicAnalysis.Key] = { range in
            if range.start == 0 { throw CocoaError(.fileReadUnknown) }
            if range.start == 22.5 { return [] }
            return [.init(interval: range, pitchClass: 2, name: "D", isMinor: true)]
        }
        let rhythm: @Sendable (MusicAnalysis.Interval) async throws
            -> MusicAnalysisService.ExcerptRhythm? = { context in
            if context.start == 15 { throw CocoaError(.fileReadUnknown) }
            return RhythmRequestRecorder.result(for: context)
        }
        var expected = original
        expected.applyRhythmExcerpts(try await service.rhythmExcerpts(for: original, analyze: rhythm))
        expected = try await service.refineKeys(in: expected, analyze: key)
        let gate = AnalysisGate()
        let progress = RefinementProgress()
        let task = Task {
            try await service.refineAnalysis(in: original, analyzeRhythm: { context in
                if context.start == 0 { _ = await gate.analyze(URL(fileURLWithPath: "/rhythm")) }
                return try await rhythm(context)
            }, analyzeKey: { range in
                if range.start == 0 { _ = await gate.analyze(URL(fileURLWithPath: "/key")) }
                return try await key(range)
            }, onProgress: { await progress.append($0) })
        }
        // Neither blocked branch can finish before both have started.
        await gate.waitForRequest("rhythm")
        await gate.waitForRequest("key")
        let first = keyReleasedFirst ? "key" : "rhythm"
        let second = keyReleasedFirst ? "rhythm" : "key"
        await gate.finish(first, bpm: 120)
        if !keyReleasedFirst { await progress.waitForRhythm() }
        await gate.finish(second, bpm: 120)
        let actual = try await task.value
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(actual) == encoder.encode(expected))
        let partials = await progress.values
        #expect(partials.count == 2)
        #expect(partials.allSatisfy { $0.keys.isEmpty })
        #expect(partials.first?.beats.isEmpty == true)
        #expect(partials.last?.beats == expected.beats)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationStopsBothRefinementBranches() async throws {
        let gate = AnalysisGate()
        let progress = RefinementProgress()
        let task = Task {
            try await MusicAnalysisService().refineAnalysis(in: MusicAnalysis(duration: 90), analyzeRhythm: { context in
                #expect(context.start == 0)
                _ = await gate.analyze(URL(fileURLWithPath: "/rhythm"))
                try Task.checkCancellation()
                return nil
            }, analyzeKey: { range in
                #expect(range.start == 0)
                _ = await gate.analyze(URL(fileURLWithPath: "/key"))
                try Task.checkCancellation()
                return []
            }, onProgress: { await progress.append($0) })
        }
        await gate.waitForRequest("rhythm")
        await gate.waitForRequest("key")
        task.cancel()
        await gate.finish("rhythm", bpm: 120)
        await gate.finish("key", bpm: 120)
        do {
            _ = try await task.value
            Issue.record("Both refinement branches should be cancelled")
        } catch is CancellationError {
        }
        #expect(await progress.values.count == 1)
    }

    @Test func localKeyFailuresAndEmptyResultsPreserveOriginalEstimate() async throws {
        let original = MusicAnalysis(duration: 90, keys: [
            .init(interval: .init(start: 0, end: 90), pitchClass: 0, name: "C", isMinor: false)
        ])
        let refined = try await MusicAnalysisService().refineKeys(in: original) { range in
            if range.start == 0 { throw CocoaError(.fileReadUnknown) }
            if range.start == 30 { return [] }
            return [.init(interval: range, pitchClass: 2, name: "D", isMinor: true)]
        }
        #expect(refined.keyLabel(at: 0, transposition: 0) == "C")
        #expect(refined.keyLabel(at: 30, transposition: 0) == "C")
        #expect(refined.keyLabel(at: 60, transposition: 0) == "Dm")
    }

    @Test func cancelledKeyAnalysisStopsBeforeNextSection() async throws {
        let gate = AnalysisGate()
        let task = Task {
            try await MusicAnalysisService().refineKeys(in: MusicAnalysis(duration: 90)) { _ in
                _ = await gate.analyze(URL(fileURLWithPath: "/key-cancel"))
                return []
            }
        }
        await gate.waitForRequest("key-cancel")
        task.cancel()
        await gate.finish("key-cancel", bpm: 120)
        do {
            _ = try await task.value
            Issue.record("Cancelled key refinement should throw")
        } catch is CancellationError {
        }
    }

    @Test func reusesOnlyIdenticalContextsAndPreservesEveryRequestedRange() async throws {
        for duration in [61.0, 180.0, 253.73333333333332] {
            let analysis = MusicAnalysis(duration: duration)
            let recorder = RhythmRequestRecorder()
            let excerpts = try await MusicAnalysisService().rhythmExcerpts(for: analysis) { context in
                await recorder.analyze(context)
            }
            let ranges = analysis.rhythmAnalysisRanges()
            let contexts = ranges.map { analysis.rhythmAnalysisContext(for: $0) }
            #expect(await recorder.requests.count == Set(contexts).count)
            #expect(excerpts.map(\.range) == ranges)
            #expect(excerpts.map(\.context) == contexts)
            // Compare the assembled result to executing every original request without reuse.
            let reference = ranges.map { range in
                let context = analysis.rhythmAnalysisContext(for: range)
                let rhythm = RhythmRequestRecorder.result(for: context)
                return MusicAnalysis.RhythmExcerpt(range: range, context: context,
                    beats: rhythm.beats, bars: rhythm.bars)
            }
            var expected = analysis
            var actual = analysis
            expected.applyRhythmExcerpts(reference)
            actual.applyRhythmExcerpts(excerpts)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #expect(try encoder.encode(actual) == encoder.encode(expected))
            let tempo = actual.tempoByBeat()
            #expect(actual.displayedBPM(at: 8, tempoByBeat: tempo, rate: 1) == 74)
            #expect(actual.displayedBPM(at: 40, tempoByBeat: tempo, rate: 1) == 148)
        }
    }

    @Test(arguments: [false, true])
    func retriesUnsuccessfulDuplicateContexts(throwsError: Bool) async throws {
        let recorder = RhythmRetryRecorder(throwsError: throwsError)
        let excerpts = try await MusicAnalysisService().rhythmExcerpts(for: MusicAnalysis(duration: 61)) { context in
            try await recorder.analyze(context)
        }
        #expect(await recorder.requests == 3)
        #expect(excerpts.count == 2)
        #expect(excerpts.last?.range.start == 60)
    }

    @Test func cancelledWorkDoesNotStartRemainingContexts() async throws {
        let gate = AnalysisGate()
        let task = Task {
            try await MusicAnalysisService().rhythmExcerpts(for: MusicAnalysis(duration: 180)) { context in
                _ = await gate.analyze(URL(fileURLWithPath: "/cancel"))
                return RhythmRequestRecorder.result(for: context)
            }
        }
        await gate.waitForRequest("cancel")
        task.cancel()
        await gate.finish("cancel", bpm: 74)
        do {
            _ = try await task.value
            Issue.record("Cancelled excerpt collection should throw")
        } catch is CancellationError {
        }
    }
}

private actor RhythmRequestRecorder {
    var requests: [MusicAnalysis.Interval] = []

    func analyze(_ context: MusicAnalysis.Interval) -> MusicAnalysisService.ExcerptRhythm {
        requests.append(context)
        return Self.result(for: context)
    }

    nonisolated static func result(for context: MusicAnalysis.Interval) -> MusicAnalysisService.ExcerptRhythm {
        let introEnd = 16 * 60.0 / 74
        let beats = (0..<16).map { Double($0) * 60 / 74 }
            + (0..<700).map { introEnd + Double($0) * 60 / 148 }
        return .init(
            beats: beats.filter { context.contains($0) },
            bars: beats.enumerated().filter { $0.offset % 4 == 0 && context.contains($0.element) }.map(\.element)
        )
    }
}

private actor RhythmRetryRecorder {
    let throwsError: Bool
    var requests = 0

    init(throwsError: Bool) { self.throwsError = throwsError }

    func analyze(_ context: MusicAnalysis.Interval) throws -> MusicAnalysisService.ExcerptRhythm? {
        requests += 1
        if requests == 2 {
            if throwsError { throw CocoaError(.fileReadUnknown) }
            return nil
        }
        return RhythmRequestRecorder.result(for: context)
    }
}

private actor RefinementProgress {
    var values: [MusicAnalysis] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func append(_ analysis: MusicAnalysis) {
        values.append(analysis)
        if values.count == 2 {
            waiter?.resume()
            waiter = nil
        }
    }

    func waitForRhythm() async {
        if values.count == 2 { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

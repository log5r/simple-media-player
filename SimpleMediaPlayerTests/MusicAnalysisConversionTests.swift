import CoreMedia
import Foundation
import MusicUnderstanding
import Testing
@testable import SimpleMediaPlayer

struct MusicAnalysisConversionTests {
    @available(macOS 27, iOS 27, *)
    @Test func emptyFrameworkResultPreservesDurationAndEmptyFeatures() async throws {
        let result = try JSONDecoder().decode(MusicUnderstandingSession.SessionResult.self, from: Data("{}".utf8))
        let analysis = await MusicAnalysisService(cacheDirectory: nil).convert(result, duration: 12)
        #expect(analysis.duration == 12)
        #expect(analysis.sections.isEmpty)
        #expect(analysis.pace.isEmpty)
        #expect(analysis.keys.isEmpty)
        #expect(analysis.beats.isEmpty)
        #expect(analysis.bars.isEmpty)
        #expect(analysis.bpm == nil)
    }

    @available(macOS 27, iOS 27, *)
    @Test func rangesAreClippedSortedAndInvalidValuesDiscarded() async throws {
        let ranges = [range(8, 5), range(-2, 3), range(11, 2), range(2, 0), CMTimeRange.invalid]
        let fixture = AnalysisResultFixture(
            structure: .init(sections: ranges),
            pace: .init(ranges: [
                .init(range: range(-2, 5), value: -1),
                .init(range: range(8, 5), value: 0.75),
                .init(range: range(3, 2), value: .nan),
                .init(range: range(3, 2), value: .infinity),
                .init(range: range(11, 2), value: 1)
            ])
        )
        let analysis = await MusicAnalysisService(cacheDirectory: nil).convert(try fixture.decode(), duration: 10)
        #expect(analysis.sections == [.init(start: 0, end: 1), .init(start: 8, end: 10)])
        #expect(analysis.pace.map(\.interval) == [.init(start: 0, end: 3), .init(start: 8, end: 10)])
        #expect(analysis.pace.map(\.value) == [0, 0.75])
    }

    @available(macOS 27, iOS 27, *)
    @Test func rhythmDeduplicatesOrdersAndFiltersNonfiniteAndOutOfRangeTimes() async throws {
        let fixture = AnalysisResultFixture(rhythm: .init(
            beats: [time(4), time(1), time(1), time(-1), time(10), .invalid, .positiveInfinity],
            bars: [time(4), time(0), time(4), time(12), .indefinite], beatsPerMinute: 123.5
        ))
        let analysis = await MusicAnalysisService(cacheDirectory: nil).convert(try fixture.decode(), duration: 10)
        #expect(analysis.beats == [1, 4])
        #expect(analysis.bars == [0, 4])
        #expect(analysis.bpm == 123.5)
    }

    @available(macOS 27, iOS 27, *)
    @Test(arguments: [
        (KeyResult.Tonic.c, (0, "C")), (KeyResult.Tonic.cSharp, (1, "C♯")),
        (KeyResult.Tonic.dFlat, (1, "D♭")), (KeyResult.Tonic.d, (2, "D")),
        (KeyResult.Tonic.dSharp, (3, "D♯")), (KeyResult.Tonic.eFlat, (3, "E♭")),
        (KeyResult.Tonic.e, (4, "E")), (KeyResult.Tonic.f, (5, "F")),
        (KeyResult.Tonic.fSharp, (6, "F♯")), (KeyResult.Tonic.gFlat, (6, "G♭")),
        (KeyResult.Tonic.g, (7, "G")), (KeyResult.Tonic.gSharp, (8, "G♯")),
        (KeyResult.Tonic.aFlat, (8, "A♭")), (KeyResult.Tonic.a, (9, "A")),
        (KeyResult.Tonic.aSharp, (10, "A♯")), (KeyResult.Tonic.bFlat, (10, "B♭")),
        (KeyResult.Tonic.b, (11, "B"))
    ], [false, true])
    func convertsEveryTonicAndMode(tone: (KeyResult.Tonic, (Int, String)), minor: Bool) async throws {
        let mode: KeyResult.Mode = minor ? .minor : .major
        let signature = AnalysisFixtureSignature(tonic: tone.0, mode: mode)
        let fixture = AnalysisResultFixture(key: .init(ranges: [
            .init(range: range(-1, 4), value: signature), .init(range: range(10, 2), value: signature)
        ]))
        let analysis = await MusicAnalysisService(cacheDirectory: nil).convert(try fixture.decode(), duration: 10)
        #expect(analysis.keys.count == 1)
        #expect(analysis.keys.first?.interval == .init(start: 0, end: 3))
        #expect(analysis.keys.first?.pitchClass == tone.1.0)
        #expect(analysis.keys.first?.name == tone.1.1)
        #expect(analysis.keys.first?.isMinor == minor)
    }

    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), duration: time(duration))
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48_000)
    }
}

/// Uses the SDK's public Codable entry point, including CoreMedia's encoding, without running the ML session.
@available(macOS 27, iOS 27, *)
private struct AnalysisResultFixture: Encodable {
    var structure: AnalysisFixtureStructure?
    var pace: AnalysisFixtureRanges<Double>?
    var key: AnalysisFixtureRanges<AnalysisFixtureSignature>?
    var rhythm: AnalysisFixtureRhythm?

    func decode() throws -> MusicUnderstandingSession.SessionResult {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return try decoder.decode(MusicUnderstandingSession.SessionResult.self, from: encoder.encode(self))
    }
}

@available(macOS 27, iOS 27, *)
private struct AnalysisFixtureStructure: Encodable {
    var sections: [CMTimeRange]
    var segments: [CMTimeRange] = []
    var phrases: [CMTimeRange] = []

    private enum CodingKeys: String, CodingKey { case sections, segments, phrases }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sections.map(EncodedCMTimeRange.init), forKey: .sections)
        try container.encode(segments.map(EncodedCMTimeRange.init), forKey: .segments)
        try container.encode(phrases.map(EncodedCMTimeRange.init), forKey: .phrases)
    }
}

@available(macOS 27, iOS 27, *)
private struct AnalysisFixtureRanged<Value: Encodable>: Encodable {
    var range: CMTimeRange
    var value: Value

    private enum CodingKeys: String, CodingKey { case range, value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EncodedCMTimeRange(range), forKey: .range)
        try container.encode(value, forKey: .value)
    }
}

@available(macOS 27, iOS 27, *)
private struct AnalysisFixtureRanges<Value: Encodable>: Encodable {
    var ranges: [AnalysisFixtureRanged<Value>]
}

@available(macOS 27, iOS 27, *)
private struct AnalysisFixtureSignature: Encodable {
    var tonic: KeyResult.Tonic
    var mode: KeyResult.Mode
}

@available(macOS 27, iOS 27, *)
private struct AnalysisFixtureRhythm: Encodable {
    var beats: [CMTime]
    var bars: [CMTime]
    var beatsPerMinute: Float?

    private enum CodingKeys: String, CodingKey { case beats, bars, beatsPerMinute }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(beats.map(EncodedCMTime.init), forKey: .beats)
        try container.encode(bars.map(EncodedCMTime.init), forKey: .bars)
        try container.encodeIfPresent(beatsPerMinute, forKey: .beatsPerMinute)
    }
}

@available(macOS 27, iOS 27, *)
private struct EncodedCMTimeRange: Encodable {
    let range: CMTimeRange

    private enum CodingKeys: String, CodingKey { case start, duration }

    init(_ range: CMTimeRange) { self.range = range }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EncodedCMTime(range.start), forKey: .start)
        try container.encode(EncodedCMTime(range.duration), forKey: .duration)
    }
}

@available(macOS 27, iOS 27, *)
private struct EncodedCMTime: Encodable {
    let time: CMTime

    private enum CodingKeys: String, CodingKey { case value, timescale, flags, epoch }

    init(_ time: CMTime) { self.time = time }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time.value, forKey: .value)
        try container.encode(time.timescale, forKey: .timescale)
        try container.encode(time.flags.rawValue, forKey: .flags)
        try container.encode(time.epoch, forKey: .epoch)
    }
}

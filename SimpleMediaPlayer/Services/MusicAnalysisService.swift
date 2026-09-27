@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import MusicUnderstanding
import Observation
import OSLog

@MainActor
@Observable
final class MusicAnalysisController {
    enum Status {
        case idle, analyzing, ready, unavailable, failed
    }

    private(set) var result: MusicAnalysis?
    private(set) var paceLevels: [Double?] = []
    private(set) var tempoByBeat: [Double?] = []
    private(set) var status: Status = .idle
    private(set) var failureReason: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let analyze: @Sendable (
        URL, @Sendable (MusicAnalysis) async -> Void
    ) async throws -> MusicAnalysis

    init(
        analyzeWithProgress: @escaping @Sendable (
            URL, @Sendable (MusicAnalysis) async -> Void
        ) async throws -> MusicAnalysis = { url, progress in
            try await MusicAnalysisService.shared.analyze(url: url, onProgress: progress)
        }
    ) {
        self.analyze = analyzeWithProgress
    }

    init(analyze: @escaping @Sendable (URL) async throws -> MusicAnalysis) {
        self.analyze = { url, _ in try await analyze(url) }
    }

    func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        result = nil
        paceLevels = []
        tempoByBeat = []
        status = .idle
        failureReason = nil
    }

    @discardableResult
    func load(url: URL) -> Task<Void, Never>? {
        reset()
        guard #available(macOS 27, iOS 27, *) else {
            status = .unavailable
            return nil
        }
        status = .analyzing
        let generation = generation
        let analyze = analyze
        task = Task(priority: .utility) { [weak self] in
            do {
                let result = try await analyze(url) { [weak self] partial in
                    await self?.accept(partial, generation: generation, status: .analyzing)
                }
                await self?.accept(result, generation: generation, status: .ready)
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.failureReason = error.localizedDescription
                self.status = .failed
            }
        }
        return task
    }

    private func accept(_ result: MusicAnalysis, generation: UUID, status: Status) async {
        guard !Task.isCancelled, self.generation == generation else { return }
        let displayData = await MusicAnalysisService.shared.displayData(for: result)
        guard !Task.isCancelled, self.generation == generation else { return }
        self.result = result
        paceLevels = displayData.pace
        tempoByBeat = displayData.tempo
        self.status = status
    }

    deinit { task?.cancel() }
}

actor MusicAnalysisService {
    static let shared = MusicAnalysisService()
    private let logger = Logger(subsystem: "SimpleMediaPlayer", category: "MusicAnalysis")

    private func logDuration(_ stage: String, since start: ContinuousClock.Instant) {
        logger.info("\(stage, privacy: .public): \(String(describing: start.duration(to: .now)), privacy: .public)")
    }

    func displayData(for result: MusicAnalysis) -> (pace: [Double?], tempo: [Double?]) {
        (result.paceOverview(), result.tempoByBeat())
    }

    func analyze(
        url: URL,
        onProgress: @Sendable (MusicAnalysis) async -> Void = { _ in }
    ) async throws -> MusicAnalysis {
        guard #available(macOS 27, iOS 27, *) else { throw CancellationError() }
        let started = ContinuousClock.now
        defer { logDuration("Total (including cache lookup; may be cancelled or failed)", since: started) }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()

        let cacheURL = cacheURL(for: url)
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let result = try? JSONDecoder().decode(MusicAnalysis.self, from: data) {
            logger.info("Cache hit")
            return result
        }

        logger.info("Cache miss")
        let wholeSongStarted = ContinuousClock.now
        let analysisURL = try ExtendedAudioSource.readableURL(for: url)
        let asset = AVURLAsset(url: analysisURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MusicUnderstandingError.invalidAsset }
        let session = try await MusicUnderstandingSession(asset: asset)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await session.analyze(for: [.structure, .pace, .rhythm, .key])
        } onCancel: {
            Task { await session.cancel() }
        }
        try Task.checkCancellation()
        let base = convert(result, duration: duration)
        logDuration("Whole song (including asset preparation)", since: wholeSongStarted)
        let analysis = try await refineAnalysis(in: base, analyzeRhythm: { context in
            try await self.analyzeRhythm(asset: asset, context: context)
        }, analyzeKey: { range in
            try await self.analyzeKey(asset: asset, range: range)
        }, onProgress: onProgress)
        try Task.checkCancellation()
        if let cacheURL, let data = try? JSONEncoder().encode(analysis) {
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL, options: .atomic)
        }
        return analysis
    }

    func refineAnalysis(in original: MusicAnalysis,
                        analyzeRhythm: @escaping @Sendable (MusicAnalysis.Interval) async throws -> ExcerptRhythm?,
                        analyzeKey: @escaping @Sendable (MusicAnalysis.Interval) async throws -> [MusicAnalysis.Key],
                        onProgress: @Sendable (MusicAnalysis) async -> Void = { _ in }) async throws -> MusicAnalysis {
        let started = ContinuousClock.now
        defer { logDuration("Local refinement (may be cancelled)", since: started) }
        try Task.checkCancellation()
        var analysis = original
        if !analysis.rhythmAnalysisRanges().isEmpty {
            // Whole-song rhythm may miss local tempo changes; publish only settled features.
            var partial = analysis
            if !analysis.keyAnalysisRanges().isEmpty { partial.keys = [] }
            partial.beats = []
            partial.bars = []
            partial.bpm = nil
            await onProgress(partial)
        }
        // Each branch processes its own ranges serially: at most two sessions per analysis.
        async let keyed = refineKeys(in: original, analyze: analyzeKey)
        let excerpts = try await rhythmExcerpts(for: original, analyze: analyzeRhythm)
        try Task.checkCancellation()
        analysis.applyRhythmExcerpts(excerpts)
        if !analysis.keyAnalysisRanges().isEmpty {
            var partial = analysis
            partial.keys = []
            await onProgress(partial)
        }
        // Merge only keys so the concurrently produced rhythm is preserved.
        analysis.keys = try await keyed.keys
        try Task.checkCancellation()
        return analysis
    }

    struct ExcerptRhythm: Sendable {
        let beats: [Double]
        let bars: [Double]
    }

    func refineKeys(
        in analysis: MusicAnalysis,
        analyze: @Sendable (MusicAnalysis.Interval) async throws -> [MusicAnalysis.Key]
    ) async throws -> MusicAnalysis {
        let started = ContinuousClock.now
        defer { logDuration("Local keys (may be cancelled)", since: started) }
        var refined = analysis
        for range in analysis.keyAnalysisRanges() {
            try Task.checkCancellation()
            do {
                let keys = try await analyze(range)
                try Task.checkCancellation()
                refined.applyKeyExcerpt(keys, range: range)
            } catch {
                try Task.checkCancellation()
                // A failed section keeps its whole-song key estimate.
            }
        }
        return refined
    }

    @available(macOS 27, iOS 27, *)
    private func analyzeKey(asset: AVURLAsset, range: MusicAnalysis.Interval) async throws -> [MusicAnalysis.Key] {
        let composition = AVMutableComposition()
        let timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 48_000),
            duration: CMTime(seconds: range.end - range.start, preferredTimescale: 48_000)
        )
        try await composition.insertTimeRange(timeRange, of: asset, at: .zero)
        let excerpt = composition.copy() as! AVComposition
        let session = try await MusicUnderstandingSession(asset: excerpt)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await session.analyze(for: [.key])
        } onCancel: {
            Task { await session.cancel() }
        }
        try Task.checkCancellation()
        return convert(result, duration: range.end - range.start).keys.map { key in
            .init(interval: .init(start: range.start + key.interval.start, end: range.start + key.interval.end),
                  pitchClass: key.pitchClass, name: key.name, isMinor: key.isMinor)
        }
    }

    func rhythmExcerpts(
        for analysis: MusicAnalysis,
        analyze: @Sendable (MusicAnalysis.Interval) async throws -> ExcerptRhythm?
    ) async throws -> [MusicAnalysis.RhythmExcerpt] {
        let started = ContinuousClock.now
        defer { logDuration("Local rhythm (may be cancelled)", since: started) }
        var results: [MusicAnalysis.Interval: ExcerptRhythm] = [:]
        var excerpts: [MusicAnalysis.RhythmExcerpt] = []
        for range in analysis.rhythmAnalysisRanges() {
            try Task.checkCancellation()
            let context = analysis.rhythmAnalysisContext(for: range)
            do {
                let rhythm: ExcerptRhythm?
                if let cached = results[context] {
                    rhythm = cached
                } else {
                    rhythm = try await analyze(context)
                    // Retry failures and empty results if another range needs this context.
                    if let rhythm, rhythm.beats.count >= 2,
                       rhythm.beats.allSatisfy({ $0.isFinite }) {
                        results[context] = rhythm
                    }
                }
                try Task.checkCancellation()
                if let rhythm {
                    excerpts.append(.init(range: range, context: context,
                                          beats: rhythm.beats, bars: rhythm.bars))
                }
            } catch {
                try Task.checkCancellation()
                // Retain the full-song result only where excerpt analysis is unavailable.
            }
        }
        return excerpts
    }

    @available(macOS 27, iOS 27, *)
    private func analyzeRhythm(asset: AVURLAsset, context: MusicAnalysis.Interval) async throws -> ExcerptRhythm? {
        let composition = AVMutableComposition()
        let timeRange = CMTimeRange(
            start: CMTime(seconds: context.start, preferredTimescale: 48_000),
            duration: CMTime(seconds: context.end - context.start, preferredTimescale: 48_000)
        )
        try await composition.insertTimeRange(timeRange, of: asset, at: .zero)
        // Only the immutable copy crosses into the session's actor.
        let excerpt = composition.copy() as! AVComposition
        let session = try await MusicUnderstandingSession(asset: excerpt)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await session.analyze(for: [.rhythm])
        } onCancel: {
            Task { await session.cancel() }
        }
        try Task.checkCancellation()
        return result.rhythm.map { rhythm in
            ExcerptRhythm(beats: rhythm.beats.map { context.start + $0.seconds },
                          bars: rhythm.bars.map { context.start + $0.seconds })
        }
    }

    private func cacheURL(for url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate,
              let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let identity = "v5|\(url.standardizedFileURL.absoluteString)|\(size)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("SimpleMediaPlayer/MusicAnalysis", isDirectory: true)
            .appendingPathComponent(digest).appendingPathExtension("json")
    }

    @available(macOS 27, iOS 27, *)
    private func convert(_ result: MusicUnderstandingSession.SessionResult, duration: Double) -> MusicAnalysis {
        func interval(_ range: CMTimeRange) -> MusicAnalysis.Interval? {
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, end > start, end > 0, start < duration else { return nil }
            return .init(start: max(0, start), end: min(duration, end))
        }
        func times(_ values: [CMTime]) -> [Double] {
            Array(Set(values.map(\.seconds).filter { $0.isFinite && $0 >= 0 && $0 < duration })).sorted()
        }
        let tones: [KeyResult.Tonic: (Int, String)] = [
            .c: (0, "C"), .cSharp: (1, "C♯"), .dFlat: (1, "D♭"), .d: (2, "D"),
            .dSharp: (3, "D♯"), .eFlat: (3, "E♭"), .e: (4, "E"), .f: (5, "F"),
            .fSharp: (6, "F♯"), .gFlat: (6, "G♭"), .g: (7, "G"), .gSharp: (8, "G♯"),
            .aFlat: (8, "A♭"), .a: (9, "A"), .aSharp: (10, "A♯"), .bFlat: (10, "B♭"), .b: (11, "B")
        ]
        return MusicAnalysis(
            duration: duration,
            sections: (result.structure?.sections ?? []).compactMap(interval).sorted { $0.start < $1.start },
            pace: (result.pace?.ranges ?? []).compactMap {
                guard let range = interval($0.range), $0.value.isFinite else { return nil }
                return .init(interval: range, value: max(0, $0.value))
            },
            keys: (result.key?.ranges ?? []).compactMap {
                guard let range = interval($0.range), let tone = tones[$0.value.tonic] else { return nil }
                return .init(interval: range, pitchClass: tone.0, name: tone.1, isMinor: $0.value.mode == .minor)
            },
            beats: times(result.rhythm?.beats ?? []),
            bars: times(result.rhythm?.bars ?? []),
            bpm: result.rhythm?.beatsPerMinute.map(Double.init)
        )
    }
}

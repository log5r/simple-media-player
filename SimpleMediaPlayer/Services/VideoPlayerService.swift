import AVFoundation
import Foundation
import MediaToolbox
import Synchronization

@MainActor
@Observable
final class VideoPlayerService {
    let player = AVPlayer()
    private let analyzer: SpectrumAnalyzer
    private var endObserver: NSObjectProtocol?
    private var audioTapProcessor: VideoAudioTapProcessor?
    private var equalizerSettings = EqualizerSettings.flat
    private var loadGeneration = 0
    private var playbackRequested = false
    private var seekGeneration = 0
    private var seekPending = false

    var currentTime: TimeInterval {
        let time = player.currentTime().seconds
        return time.isFinite ? max(0, time) : 0
    }
    var duration: TimeInterval = 0
    var onFinished: (() -> Void)?
    var onFormatLoaded: (@MainActor (MediaFormatInfo) -> Void)?

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    func load(url: URL) async {
        loadGeneration += 1
        playbackRequested = false
        seekPending = false
        seekGeneration &+= 1
        audioTapProcessor?.state.setActive(false)
        player.pause()
        let generation = loadGeneration
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let processor = await audioTapProcessor(for: item, asset: asset)
        guard generation == loadGeneration else { return }
        audioTapProcessor = processor
        player.replaceCurrentItem(with: item)
        let loadedDuration = (try? await asset.load(.duration).seconds) ?? 0
        guard generation == loadGeneration else { return }
        duration = loadedDuration.isFinite && loadedDuration > 0 ? loadedDuration : 0
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onFinished?()
            }
        }
        let formatInfo = await Self.formatInfo(for: asset, url: url, duration: duration)
        guard generation == loadGeneration else { return }
        onFormatLoaded?(formatInfo)
    }

    func play() {
        playbackRequested = true
        audioTapProcessor?.state.setActive(!seekPending)
        player.play()
    }

    func pause() {
        playbackRequested = false
        audioTapProcessor?.state.setActive(false)
        player.pause()
    }

    func setVolume(_ volume: Float) {
        player.volume = max(0, min(1, volume))
    }

    func setEqualizer(_ settings: EqualizerSettings) {
        equalizerSettings = settings
        audioTapProcessor?.setEqualizer(settings)
    }

    func stop() {
        pause()
        seek(to: 0)
    }

    func close() {
        loadGeneration += 1
        stop()
        player.replaceCurrentItem(with: nil)
        duration = 0
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        audioTapProcessor = nil
    }

    func seek(to time: TimeInterval) {
        let processor = audioTapProcessor
        processor?.state.setActive(false)
        seekGeneration &+= 1
        seekPending = true
        let request = seekGeneration
        let generation = loadGeneration
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.loadGeneration, request == self.seekGeneration else { return }
                self.seekPending = false
                processor?.state.setActive(self.playbackRequested)
            }
        }
    }

    private func audioTapProcessor(for item: AVPlayerItem, asset: AVAsset) async -> VideoAudioTapProcessor? {
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            item.audioMix = nil
            return nil
        }

        let processor = VideoAudioTapProcessor(analyzer: analyzer, equalizerSettings: equalizerSettings)
        guard let tap = processor.makeTap() else {
            item.audioMix = nil
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.audioTapProcessor = tap

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]
        item.audioMix = audioMix
        return processor
    }

    private static func formatInfo(for asset: AVURLAsset, url: URL, duration: TimeInterval) async -> MediaFormatInfo {
        var sampleRateHz: Double?
        var bitrateKbps: Int?
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            if let formatDescriptions = try? await audioTrack.load(.formatDescriptions),
               let formatDescription = formatDescriptions.first,
               let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
               streamDescription.mSampleRate > 0 {
                sampleRateHz = streamDescription.mSampleRate
            }
            if let dataRate = try? await audioTrack.load(.estimatedDataRate) {
                bitrateKbps = kbps(fromBitsPerSecond: Double(dataRate))
            }
        }

        var videoFrameRateFps: Double?
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
           let frameRate = try? await videoTrack.load(.nominalFrameRate),
           frameRate > 0 {
            videoFrameRateFps = Double(frameRate)
        }

        return MediaFormatInfo(
            sampleRateHz: sampleRateHz,
            bitrateKbps: bitrateKbps,
            videoFrameRateFps: videoFrameRateFps,
            totalBitrateKbps: await totalBitrateKbps(for: asset, url: url, duration: duration)
        )
    }

    private static func totalBitrateKbps(for asset: AVURLAsset, url: URL, duration: TimeInterval) async -> Int? {
        if let tracks = try? await asset.load(.tracks) {
            var totalBitsPerSecond = 0.0
            for track in tracks {
                if let dataRate = try? await track.load(.estimatedDataRate), dataRate > 0 {
                    totalBitsPerSecond += Double(dataRate)
                }
            }

            if let bitrateKbps = kbps(fromBitsPerSecond: totalBitsPerSecond) {
                return bitrateKbps
            }
        }

        guard duration > 0,
              let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              fileSize > 0
        else {
            return nil
        }
        return kbps(fromBitsPerSecond: Double(fileSize) * 8 / duration)
    }

    private static func kbps(fromBitsPerSecond bitsPerSecond: Double) -> Int? {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return nil }
        let value = Int((bitsPerSecond / 1000).rounded())
        return value > 0 ? value : nil
    }
}

nonisolated private final class VideoAudioTapProcessor: @unchecked Sendable {
    private let analyzer: SpectrumAnalyzer
    private let equalizer: VideoEqualizerProcessor
    let state = VideoAudioTapState()
    private var sampleRing: VideoAudioSampleRing?
    private var supportsFloat32 = false

    init(analyzer: SpectrumAnalyzer, equalizerSettings: EqualizerSettings) {
        self.analyzer = analyzer
        self.equalizer = VideoEqualizerProcessor(settings: equalizerSettings)
    }

    func setEqualizer(_ settings: EqualizerSettings) {
        equalizer.setSettings(settings)
    }

    func makeTap() -> MTAudioProcessingTap? {
        let retainedSelf = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedSelf.toOpaque(),
            init: Self.initialize,
            finalize: Self.finalize,
            prepare: Self.prepare,
            unprepare: Self.unprepare,
            process: Self.process
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        if status != noErr {
            retainedSelf.release()
            return nil
        }
        return tap
    }

    private static func processor(from tap: MTAudioProcessingTap) -> VideoAudioTapProcessor? {
        let storage = MTAudioProcessingTapGetStorage(tap)
        return Unmanaged<VideoAudioTapProcessor>.fromOpaque(storage).takeUnretainedValue()
    }

    private static let initialize: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
        tapStorageOut.pointee = clientInfo
    }

    private static let finalize: MTAudioProcessingTapFinalizeCallback = { tap in
        let storage = MTAudioProcessingTapGetStorage(tap)
        Unmanaged<VideoAudioTapProcessor>.fromOpaque(storage).release()
    }

    private static let prepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, processingFormat in
        guard let processor = processor(from: tap),
              let format = AVAudioFormat(streamDescription: processingFormat)
        else {
            return
        }
        processor.equalizer.prepare(format: format)
        processor.supportsFloat32 = format.commonFormat == .pcmFormatFloat32
        guard processor.supportsFloat32, maxFrames > 0, format.channelCount > 0,
              format.sampleRate.isFinite, format.sampleRate > 0 else { return }
        let ring = VideoAudioSampleRing(maxFrames: maxFrames, format: format, state: processor.state)
        processor.sampleRing = ring
        ring.start(analyzer: processor.analyzer)
    }

    private static let unprepare: MTAudioProcessingTapUnprepareCallback = { tap in
        guard let processor = processor(from: tap) else { return }
        processor.sampleRing?.stop()
        processor.sampleRing = nil
        processor.supportsFloat32 = false
    }

    private static let process: MTAudioProcessingTapProcessCallback =
    { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
        guard let processor = processor(from: tap) else { return }
        // Capture validity before fetching audio, so a concurrent transport change
        // cannot assign old source audio to a new playback epoch.
        let sourceEpoch = processor.state.epoch.load(ordering: .acquiring)
        let analysisGeneration = processor.analyzer.realtimeVideoGeneration
        var timeRange = CMTimeRange.invalid
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            numberFrames,
            bufferListInOut,
            flagsOut,
            &timeRange,
            numberFramesOut
        )
        guard status == noErr, processor.supportsFloat32, numberFramesOut.pointee > 0 else { return }
        let startsStream = flagsOut.pointee
            & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream) != 0
        if startsStream { processor.equalizer.reset() }
        let frameCount = numberFramesOut.pointee
        processor.equalizer.process(bufferListInOut, frameCount: frameCount)
        processor.sampleRing?.enqueue(
            bufferListInOut, frameCount: frameCount,
            stamp: VideoAudioSampleRing.Stamp(
                time: timeRange.start.seconds, analysisGeneration: analysisGeneration,
                sourceEpoch: sourceEpoch, startsStream: startsStream
            )
        )
    }
}

extension VideoPlayerService: VideoPlaybackControlling {}

import AVFoundation
import Foundation
import MediaToolbox

@MainActor
@Observable
final class VideoPlayerService {
    let player = AVPlayer()
    private let analyzer: SpectrumAnalyzer
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var audioTapProcessor: VideoAudioTapProcessor?
    private var equalizerSettings = EqualizerSettings.flat
    private var loadGeneration = 0

    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var onFinished: (() -> Void)?
    var onFormatLoaded: (@MainActor (MediaFormatInfo) -> Void)?

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    func load(url: URL) async {
        loadGeneration += 1
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
        player.play()
    }

    func pause() {
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
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = 0
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
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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

private final class VideoAudioTapProcessor: @unchecked Sendable {
    private let analyzer: SpectrumAnalyzer
    private let equalizer: VideoEqualizerProcessor
    private var format: AVAudioFormat?

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
            unprepare: nil,
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

    private static let prepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
        guard let processor = processor(from: tap),
              let format = AVAudioFormat(streamDescription: processingFormat)
        else {
            return
        }
        processor.format = format
        processor.equalizer.prepare(format: format)
    }

    private static let process: MTAudioProcessingTapProcessCallback =
    { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
        var timeRange = CMTimeRange.invalid
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            numberFrames,
            bufferListInOut,
            flagsOut,
            &timeRange,
            numberFramesOut
        )
        guard status == noErr,
              let processor = processor(from: tap),
              let format = processor.format,
              numberFramesOut.pointee > 0
        else {
            return
        }

        let bufferListPointer = UnsafePointer<AudioBufferList>(bufferListInOut)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: bufferListPointer,
            deallocator: nil
        ) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(numberFramesOut.pointee)
        if flagsOut.pointee & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream) != 0 {
            processor.equalizer.reset()
        }
        processor.equalizer.process(buffer)
        processor.analyzer.analyze(buffer, currentTime: timeRange.start.seconds, isPlaying: true)
    }
}

extension VideoPlayerService: VideoPlaybackControlling {}

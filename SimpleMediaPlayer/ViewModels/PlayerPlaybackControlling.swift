import AVFoundation
import Foundation

@MainActor
protocol MediaURLResolving: AnyObject {
    func resolvedURL(for item: MediaItem) -> URL?
}

@MainActor
protocol AudioPlaybackControlling: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var onFinished: (@MainActor () -> Void)? { get set }
    var onError: (@MainActor (String) -> Void)? { get set }
    var onFormatLoaded: (@MainActor (_ duration: TimeInterval, _ formatInfo: MediaFormatInfo) -> Void)? { get set }

    func setVolume(_ volume: Float)
    func setPitchCents(_ cents: Float)
    func setPlaybackRate(_ rate: Float)
    func setVolumeNormalizationEnabled(_ enabled: Bool)
    func setEqualizer(_ settings: EqualizerSettings)
    func load(url: URL)
    func play()
    func pause()
    func stop(reset: Bool)
    func suspend()
    func seek(to time: TimeInterval, autoPlay: Bool)
    func resetEngine()
}

@MainActor
protocol VideoPlaybackControlling: AnyObject {
    var player: AVPlayer { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var onFinished: (() -> Void)? { get set }
    var onFormatLoaded: (@MainActor (MediaFormatInfo) -> Void)? { get set }

    func load(url: URL) async
    func play()
    func pause()
    func setVolume(_ volume: Float)
    func setEqualizer(_ settings: EqualizerSettings)
    func stop()
    func close()
    func seek(to time: TimeInterval)
}

struct DeferredPlaybackRequest: Equatable {
    let id: UUID
    let transportGeneration: UInt64
}

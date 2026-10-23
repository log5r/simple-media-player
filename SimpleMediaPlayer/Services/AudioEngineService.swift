import AVFoundation
import Foundation

struct PendingSeek {
    let time: TimeInterval
    let autoPlay: Bool
    let loadID: UUID
    let seekID: UUID
}

// AVAudio 系の操作(stop / scheduleSegment など)は内部で下位 QoS スレッドとの
// 同期待ちを伴うため、すべて専用の直列キュー(controlQueue)上で実行し、
// メインスレッドをブロックさせない。UI へ公開する currentTime / duration は
// ロックで守った表示用クロックのキャッシュのみを参照する。
nonisolated final class AudioEngineService: @unchecked Sendable {
    // resetEngine() でインスタンスごと作り直すため var(controlQueue 上でのみ差し替える)
    var engine: AVAudioEngine
    var playerNode = AVAudioPlayerNode()
    var timePitch = AudioProcessingQuality.makeTimePitch()
    var pitchEffectStorage: SMPPitchEffect?
    var fadeMixer = AVAudioMixerNode()
    var loudnessGain = AVAudioUnitEQ(numberOfBands: 0)
    var graphicEQ = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)
    var reverb = AVAudioUnitReverb()
    var outputProtection = AudioOutputProtection()
    var configurationObservation: AudioEngineConfigurationObservation?
    let analyzer: SpectrumAnalyzer
    let openReadableFile: @Sendable (URL) throws -> ExtendedAudioCache.ReadableFile
    let waitForFadeStep: @Sendable (useconds_t) -> Void
    let engineFactory: @Sendable () -> AVAudioEngine
    let preparePlayer: @Sendable (AVAudioPlayerNode, AVAudioFrameCount) -> Void
    typealias IdleSchedule = @Sendable (TimeInterval, DispatchQueue, DispatchWorkItem) -> Void
    typealias FinishDelivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    let scheduleIdleSuspension: IdleSchedule?
    let deliverFinishNotification: FinishDelivery
    let controlQueue = DispatchQueue(label: "SimpleMediaPlayer.AudioEngineService.control", qos: .userInitiated)

    // controlQueue 上でのみ触る状態
    var loudnessNormalizationStorage: AudioLoudnessNormalization?
    var audioFile: AVAudioFile?
    var currentURL: URL?
    var currentReadableFile: ExtendedAudioCache.ReadableFile?
    // 最後に処理した再生操作の ID。終端通知をその操作に結び付ける
    var appliedPlaybackRequestID: UUID?
    var preparationTask: Task<Void, Never>?
    var loadGeneration = 0
    var playWhenReady = false
    var startFrame: AVAudioFramePosition = 0
    var seekFrame: AVAudioFramePosition = 0
    var sampleRate: Double = 44_100
    var scheduleGeneration = 0
    var currentEqualizerSettings = EqualizerSettings.flat
    var loadedReverbPreset: EqualizerReverbPreset?
    var idleSuspensionStorage: AudioEngineIdleSuspension?

    // メインスレッド・タップコールバックと共有する公開状態(stateLock で保護)
    let stateLock = NSLock()
    var displayBaseTime: TimeInterval = 0
    var displayElapsedTime: TimeInterval = 0
    var displayLatencyRemaining: TimeInterval = 0
    var displayIsPlaying = false
    var displayRate: Double = 1.0
    var cachedDuration: TimeInterval = 0
    var pendingSeek: PendingSeek?
    var activeLoadID = UUID()
    // 再生状態を変える操作を呼ぶたびに更新する。終端通知の有効性判定に使う
    var activePlaybackRequestID = UUID()

    var onFinished: (@MainActor () -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onFormatLoaded: (@MainActor (_ duration: TimeInterval, _ formatInfo: MediaFormatInfo) -> Void)?

    init(
        analyzer: SpectrumAnalyzer,
        openReadableFile: @escaping @Sendable (URL) throws -> ExtendedAudioCache.ReadableFile = {
            try ExtendedAudioSource.readableFile(for: $0)
        },
        waitForFadeStep: @escaping @Sendable (useconds_t) -> Void = { usleep($0) },
        scheduleIdleSuspension: IdleSchedule? = nil,
        engineFactory: @escaping @Sendable () -> AVAudioEngine = { AVAudioEngine() },
        preparePlayer: @escaping @Sendable (AVAudioPlayerNode, AVAudioFrameCount) -> Void = {
            $0.prepare(withFrameCount: $1)
        },
        deliverFinishNotification: @escaping FinishDelivery = { notification in
            Task { @MainActor in notification() }
        }
    ) {
        self.analyzer = analyzer
        self.openReadableFile = openReadableFile
        self.waitForFadeStep = waitForFadeStep
        self.scheduleIdleSuspension = scheduleIdleSuspension
        self.engineFactory = engineFactory
        self.preparePlayer = preparePlayer
        self.deliverFinishNotification = deliverFinishNotification
        engine = engineFactory()
        controlQueue.async { self.buildEngineGraph() }
    }

}

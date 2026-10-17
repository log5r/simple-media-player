import AVFoundation
import Foundation

nonisolated final class AudioEngineConfigurationObservation {
    private let token: NSObjectProtocol

    init(engine: AVAudioEngine, didChange: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in didChange() }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

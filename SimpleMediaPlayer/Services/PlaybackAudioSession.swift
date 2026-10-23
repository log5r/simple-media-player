import AVFoundation
import Foundation

/// Shares one activation between transport requests. Cancelling a waiter must not cancel another track's activation.
@MainActor
final class PlaybackAudioSession {
    private nonisolated static let configurationQueue = DispatchQueue(
        label: "SimpleMediaPlayer.AudioSession", qos: .userInitiated
    )
    private let activation: (@Sendable () async throws -> Void)?
    private var preparation: (id: UUID, task: Task<Void, any Error>)?
    private(set) var isReady: Bool

    /// Injected players are ready by default; only the app's convenience initializer uses the system session.
    init(activation: (@Sendable () async throws -> Void)? = nil) {
        self.activation = activation
        isReady = activation == nil
    }

    static func system() -> PlaybackAudioSession {
        #if os(iOS)
        PlaybackAudioSession(activation: activateSystemSession)
        #else
        PlaybackAudioSession()
        #endif
    }

    func prepare() async throws {
        guard !isReady, let activation else { return }
        let pending: (id: UUID, task: Task<Void, any Error>)
        if let preparation {
            pending = preparation
        } else {
            pending = (UUID(), Task { try await activation() })
            preparation = pending
        }
        do {
            try await pending.task.value
            if preparation?.id == pending.id {
                isReady = true
                preparation = nil
            }
        } catch {
            if preparation?.id == pending.id { preparation = nil }
            throw error
        }
    }

    nonisolated static func configureAndActivate(
        configure: @escaping @Sendable () throws -> Void,
        activate: @Sendable () async throws -> Bool
    ) async throws {
        // Setting the category can synchronously talk to the audio daemon, even when activation is asynchronous.
        let result: Result<Void, any Error> = await withCheckedContinuation { continuation in
            configurationQueue.async { continuation.resume(returning: Result { try configure() }) }
        }
        try result.get()
        let activated = try await activate()
        guard activated else { throw CocoaError(.featureUnsupported) }
    }

    #if os(iOS)
    private nonisolated static func activateSystemSession() async throws {
        try await configureAndActivate {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } activate: {
            try await AVAudioSession.sharedInstance().activate(options: [])
        }
    }
    #endif
}

import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
func waitForPlaybackToStart(_ player: PlayerViewModel) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !player.isPlaying, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(player.isPlaying, "Playback did not start before the deadline")
}

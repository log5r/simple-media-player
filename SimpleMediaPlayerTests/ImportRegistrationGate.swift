import Foundation
import Testing

/// The source has been copied and validated, but its library item is not registered yet.
@MainActor
final class ImportRegistrationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var sourceURLs: [URL] = []

    func hold(_ url: URL) async {
        sourceURLs.append(url)
        guard !isReleased else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilBlocked() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while continuations.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!continuations.isEmpty)
    }

    func release() {
        isReleased = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

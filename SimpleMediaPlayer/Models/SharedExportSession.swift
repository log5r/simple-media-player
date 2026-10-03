import Foundation

/// The scene owns exported files until a sharing activity finishes or the user cancels the session.
@MainActor
final class SharedExportSession: Identifiable {
    let id = UUID()
    let directory: URL
    let urls: [URL]
    private(set) var isCompleted = false
    private var presentationID: UUID?
    private var cleanupTask: Task<Void, Never>?

    init(directory: URL, urls: [URL]) {
        self.directory = directory
        self.urls = urls
    }

    deinit {
        guard cleanupTask == nil else { return }
        let directory = directory
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
    }

    func beginPresentation() -> UUID? {
        guard !isCompleted else { return nil }
        let identifier = UUID()
        presentationID = identifier
        return identifier
    }

    /// A controller disappearing during scene adaptation does not end the sharing session.
    func detachPresentation(_ identifier: UUID) {
        guard presentationID == identifier else { return }
        presentationID = nil
    }

    @discardableResult
    func completePresentation(_ identifier: UUID) -> Bool {
        guard !isCompleted, presentationID == identifier else { return false }
        finish()
        return true
    }

    func cancel() {
        guard !isCompleted else { return }
        finish()
    }

    func awaitCleanup() async {
        await cleanupTask?.value
    }

    private func finish() {
        isCompleted = true
        presentationID = nil
        guard cleanupTask == nil else { return }
        let directory = directory
        cleanupTask = Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
    }
}

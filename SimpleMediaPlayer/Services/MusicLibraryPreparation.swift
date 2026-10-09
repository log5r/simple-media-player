import Foundation

/// One export of Music library songs for playback or import. The progress panel and its Cancel button
/// act on this instance, so a cancelled or replaced preparation cannot update the panel or deliver its
/// result.
@MainActor
@Observable
final class MusicLibraryPreparation {
    enum Purpose: Sendable {
        case playback
        case importing
    }

    enum Termination: Sendable {
        /// The user cancelled; the caller reports the cancellation.
        case cancelled
        /// A newer preparation took over; the caller reports nothing.
        case replaced
    }

    let purpose: Purpose
    let totalCount: Int
    private(set) var completedCount = 0
    private(set) var currentTitle: String?
    private(set) var termination: Termination?
    @ObservationIgnored private var cancelHandler: (() -> Void)?

    init(purpose: Purpose, totalCount: Int) {
        self.purpose = purpose
        self.totalCount = totalCount
    }

    var fractionCompleted: Double {
        totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
    }

    func advance(to count: Int, title: String?) {
        completedCount = min(max(count, completedCount), totalCount)
        currentTitle = title
    }

    func attach<Success>(_ task: Task<Success, Error>) {
        cancelHandler = { task.cancel() }
    }

    func terminate(_ termination: Termination) {
        guard self.termination == nil else { return }
        self.termination = termination
        cancelHandler?()
        cancelHandler = nil
    }
}

nonisolated struct MusicLibraryImportResult: Sendable, Equatable {
    var importedCount = 0
    var skippedCount = 0
    var messages: [String] = []
    var wasCancelled = false

    var summary: String {
        var lines: [String] = []
        if wasCancelled {
            lines.append(L10n.string("Importing from Music was cancelled."))
        } else if importedCount > 0 {
            lines.append(L10n.format("Imported %d songs from Music.", importedCount))
        } else {
            lines.append(L10n.string("No songs were imported."))
        }
        lines.append(contentsOf: messages)
        return lines.joined(separator: "\n")
    }
}

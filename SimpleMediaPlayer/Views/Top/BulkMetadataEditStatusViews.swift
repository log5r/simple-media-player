import SwiftUI

/// Shown while a bulk metadata edit runs. Cancelling stops before the next file; a file already being
/// written still finishes.
struct BulkMetadataEditProgressRow: View {
    let progress: BulkMetadataEditProgress?
    let isCancelling: Bool
    let cancel: () -> Void

    var body: some View {
        let completedCount = progress?.completedCount ?? 0
        let totalCount = max(progress?.totalCount ?? 0, 1)
        HStack(spacing: 12) {
            ProgressView(value: Double(completedCount), total: Double(totalCount)) {
                Text("Applying \(min(completedCount + 1, totalCount)) of \(totalCount)…")
            }
            .accessibilityIdentifier("bulkEditProgress")
            Button("Cancel", action: cancel)
                .disabled(isCancelling)
                .accessibilityIdentifier("bulkEditStopButton")
        }
    }
}

struct BulkMetadataEditResultSummary: View {
    let result: BulkMetadataEditResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if result.failedCount == 0, result.unprocessedCount == 0 {
                Label("\(result.updatedCount) files updated.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                incompleteLabel
                ForEach(Array(result.failures.prefix(3))) { failure in
                    Text("\(failure.fileName): \(failure.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var incompleteLabel: some View {
        if result.failedCount == 0 {
            Label(
                "\(result.updatedCount) files updated, \(result.unprocessedCount) not processed (cancelled).",
                systemImage: "exclamationmark.triangle"
            )
                .foregroundStyle(.secondary)
        } else if result.unprocessedCount == 0 {
            Label(
                "\(result.updatedCount) files updated, \(result.failedCount) failed.",
                systemImage: "exclamationmark.triangle"
            )
                .foregroundStyle(.red)
        } else {
            Label(
                """
                \(result.updatedCount) files updated, \(result.failedCount) failed, \
                \(result.unprocessedCount) not processed (cancelled).
                """,
                systemImage: "exclamationmark.triangle"
            )
                .foregroundStyle(.red)
        }
    }
}

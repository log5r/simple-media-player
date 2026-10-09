import Foundation

/// One export plan being prepared. The progress panel and its Cancel button act on this instance, so a
/// cancelled or replaced preparation cannot update the panel or deliver its plan.
@MainActor
@Observable
final class ExportPlanPreparation {
    let totalCount: Int
    private(set) var completedCount = 0
    @ObservationIgnored fileprivate(set) var task: Task<MediaExportPlan, Error>?

    init(totalCount: Int) {
        self.totalCount = totalCount
    }

    var fractionCompleted: Double {
        totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
    }

    /// Reports can arrive out of order from the workers, so the count only moves forward.
    func recordCompletedCount(_ count: Int) {
        let count = min(count, totalCount)
        guard count > completedCount else { return }
        completedCount = count
    }
}

extension LibraryService {
    /// Starts reading export names in the background and shows the preparation through
    /// `exportPlanPreparation`. A preparation already in progress is cancelled.
    func beginExportPlanPreparation(for items: [MediaItem]) -> ExportPlanPreparation {
        cancelExportPlanPreparation()
        let preparation = ExportPlanPreparation(totalCount: items.count)
        preparation.task = Task { try await makeExportPlan(for: items, progress: preparation) }
        exportPlanPreparation = preparation
        return preparation
    }

    /// Waits for the plan of `preparation`. Returns nil when the preparation was cancelled or replaced,
    /// including when its plan was already complete at that moment.
    func exportPlan(from preparation: ExportPlanPreparation) async -> MediaExportPlan? {
        defer {
            if exportPlanPreparation === preparation { exportPlanPreparation = nil }
        }
        guard let task = preparation.task else { return nil }
        let plan = try? await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard let plan, exportPlanPreparation === preparation, Task.isCancelled == false else { return nil }
        return plan
    }

    func cancelExportPlanPreparation() {
        exportPlanPreparation?.task?.cancel()
        exportPlanPreparation = nil
    }
}

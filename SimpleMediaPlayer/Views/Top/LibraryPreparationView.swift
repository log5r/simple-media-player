import SwiftData
import SwiftUI

@MainActor
@Observable
final class LibraryPreparation {
    private(set) var isReady = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var migration: Task<Void, Error>?

    func prepare(in container: ModelContainer) async {
        guard isReady == false else { return }
        if let migration {
            _ = try? await migration.value
            return
        }
        errorMessage = nil
        let task = Task {
            try await LibraryArtworkStorage.migrate(in: container)
        }
        migration = task
        do {
            try await task.value
            isReady = true
        } catch {
            errorMessage = error.localizedDescription
        }
        migration = nil
    }
}

/// Do not create queries over legacy inline artwork until its resumable migration has finished.
struct LibraryPreparationView<Content: View>: View {
    let preparation: LibraryPreparation
    @ViewBuilder let content: () -> Content
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if preparation.isReady {
                content()
            } else if let message = preparation.errorMessage {
                ContentUnavailableView {
                    Label("Could not prepare library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await preparation.prepare(in: modelContext.container) }
                    }
                }
            } else {
                ProgressView("Preparing library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await preparation.prepare(in: modelContext.container)
        }
    }
}

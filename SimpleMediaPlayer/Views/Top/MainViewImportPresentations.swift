import SwiftUI
import UniformTypeIdentifiers

extension MainView {
    func withImportPresentations<Content: View>(_ content: Content) -> some View {
        content
        .fileImporter(
            isPresented: $isImporterPresented, allowedContentTypes: [.movie, .data], allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                startImport(urls)
            case let .failure(error):
                libraryService.lastImportErrors = [error.localizedDescription]
                importErrorPresented = true
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            startImport(urls, retainingSecurityScopedAccess: true)
            return true
        }
        .alert("Import Error", isPresented: $importErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(libraryService.lastImportErrors.joined(separator: "\n"))
        }
        .alert("Playback Error", isPresented: Binding(
            get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }
}

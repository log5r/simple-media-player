#if os(iOS)
import SwiftUI
import UIKit

enum IPhoneExportSheet: Identifiable {
    case names(MediaExportPlan)
    case share(IPhoneSharedExport)

    var id: UUID {
        switch self {
        case let .names(plan): plan.id
        case let .share(export): export.id
        }
    }
}

final class IPhoneSharedExport: Identifiable {
    let id = UUID()
    let directory: URL
    let urls: [URL]

    init(directory: URL, urls: [URL]) {
        self.directory = directory
        self.urls = urls
    }

    func cleanup() {
        let directory = directory
        Task.detached { try? FileManager.default.removeItem(at: directory) }
    }
}

struct IPhoneShareSheet: UIViewControllerRepresentable {
    let export: IPhoneSharedExport

    final class Coordinator {
        let export: IPhoneSharedExport
        init(export: IPhoneSharedExport) { self.export = export }
    }

    func makeCoordinator() -> Coordinator { Coordinator(export: export) }

    static func dismantleUIViewController(_ uiViewController: UIActivityViewController, coordinator: Coordinator) {
        coordinator.export.cleanup()
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: export.urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in export.cleanup() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

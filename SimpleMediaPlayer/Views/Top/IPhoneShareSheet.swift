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

typealias IPhoneSharedExport = SharedExportSession

struct IPhoneShareSheet: UIViewControllerRepresentable {
    let export: IPhoneSharedExport
    var onCompletion: (UUID) -> Void = { _ in }

    final class Coordinator {
        let export: IPhoneSharedExport
        let presentationID: UUID?
        private let onCompletion: (UUID) -> Void

        init(export: IPhoneSharedExport, onCompletion: @escaping (UUID) -> Void = { _ in }) {
            self.export = export
            self.onCompletion = onCompletion
            presentationID = export.beginPresentation()
        }

        func detach() {
            guard let presentationID else { return }
            export.detachPresentation(presentationID)
        }

        func complete() {
            guard let presentationID, export.completePresentation(presentationID) else { return }
            onCompletion(export.id)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(export: export, onCompletion: onCompletion) }

    static func dismantleUIViewController(_ uiViewController: UIActivityViewController, coordinator: Coordinator) {
        uiViewController.completionWithItemsHandler = nil
        coordinator.detach()
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: export.urls, applicationActivities: nil)
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { _, _, _, _ in coordinator.complete() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

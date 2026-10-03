import SwiftUI

extension MainView {
    func withExportPresentations<Content: View>(_ content: Content) -> some View {
        content
        .alert(
            exportAlertTitle,
            isPresented: $exportResultPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportResultMessage)
        }
        .alert("Create AAC Version", isPresented: aacResultPresentation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(aacVersionResultMessage)
        }
        #if os(iOS)
        .sheet(item: $phoneExportSheet, onDismiss: finishExportSheet, content: { sheet in
            switch sheet {
            case let .names(plan):
                exportNamesView(plan)
            case let .share(export):
                IPhoneShareSheet(export: export, onCompletion: finishSharingExport)
            }
        })
        #endif
        #if os(macOS)
        .sheet(item: $pendingExportPlan, onDismiss: finishExportSheet, content: { plan in
            exportNamesView(plan)
        })
        #endif
    }
    #if os(iOS)
    func finishSharingExport(_ id: UUID) {
        guard sharedExportSession?.id == id else { return }
        sharedExportSession = nil
        phoneExportSheet = nil
    }
    #endif
}

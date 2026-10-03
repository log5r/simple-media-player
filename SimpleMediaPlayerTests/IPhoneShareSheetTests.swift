#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import SimpleMediaPlayer

@MainActor
struct IPhoneShareSheetTests {
    @Test func dismantlingControllerRetainsFilesForTheNextPresentation() async throws {
        let directory = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("share-controller-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("export.wav"))
            return directory
        }.value
        let url = directory.appendingPathComponent("export.wav")
        let session = SharedExportSession(directory: directory, urls: [url])
        var completedIDs: [UUID] = []
        let coordinator = IPhoneShareSheet.Coordinator(export: session) { completedIDs.append($0) }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in coordinator.complete() }

        IPhoneShareSheet.dismantleUIViewController(controller, coordinator: coordinator)

        #expect(controller.completionWithItemsHandler == nil)
        #expect(await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value)
        let replacement = IPhoneShareSheet.Coordinator(export: session) { completedIDs.append($0) }
        coordinator.complete()
        #expect(completedIDs.isEmpty)
        replacement.complete()
        replacement.complete()
        await session.awaitCleanup()
        #expect(completedIDs == [session.id])
        #expect(await Task.detached { !FileManager.default.fileExists(atPath: directory.path) }.value)
    }
}
#endif

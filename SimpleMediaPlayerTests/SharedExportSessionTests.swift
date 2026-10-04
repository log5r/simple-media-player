import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct SharedExportSessionTests {
    @Test func detachingAndRecreatingPresentationPreservesFilesUntilCompletion() async throws {
        let directory = try await makeDirectory()
        let url = directory.appendingPathComponent("export.wav")
        let session = SharedExportSession(directory: directory, urls: [url])
        let first = try #require(session.beginPresentation())

        session.detachPresentation(first)

        #expect(await exists(url))
        #expect(!session.isCompleted)
        let replacement = try #require(session.beginPresentation())
        #expect(!session.completePresentation(first))
        #expect(await exists(url))
        #expect(session.completePresentation(replacement))
        await session.awaitCleanup()
        #expect(!(await exists(directory)))
        #expect(session.isCompleted)
        #expect(!session.completePresentation(replacement))
        #expect(session.beginPresentation() == nil)
    }

    @Test func detachingAnOldControllerDoesNotInvalidateTheReplacement() async throws {
        let directory = try await makeDirectory()
        let session = SharedExportSession(directory: directory, urls: [directory.appendingPathComponent("export.wav")])
        let first = try #require(session.beginPresentation())
        let replacement = try #require(session.beginPresentation())

        session.detachPresentation(first)

        #expect(session.completePresentation(replacement))
        await session.awaitCleanup()
        #expect(!(await exists(directory)))
    }

    @Test func explicitCancellationCleansDetachedFilesAndRejectsLateCompletion() async throws {
        let directory = try await makeDirectory()
        let session = SharedExportSession(directory: directory, urls: [directory.appendingPathComponent("export.wav")])
        let presentation = try #require(session.beginPresentation())
        session.detachPresentation(presentation)
        #expect(await exists(directory))

        session.cancel()
        session.cancel()
        await session.awaitCleanup()

        #expect(!(await exists(directory)))
        #expect(!session.completePresentation(presentation))
    }

    @Test func droppingSceneOwnershipEventuallyCleansUncompletedFiles() async throws {
        let directory = try await makeDirectory()
        var session: SharedExportSession? = SharedExportSession(
            directory: directory, urls: [directory.appendingPathComponent("export.wav")]
        )
        weak var weakSession = session
        session = nil
        #expect(weakSession == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await exists(directory), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!(await exists(directory)))
    }

    private func makeDirectory() async throws -> URL {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-export-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("export.wav"))
            return directory
        }.value
    }

    private func exists(_ url: URL) async -> Bool {
        await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
    }
}

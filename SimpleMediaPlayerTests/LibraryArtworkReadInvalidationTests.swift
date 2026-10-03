import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryArtworkReadInvalidationTests {
    @Test(arguments: ArtworkReadInvalidation.allCases)
    private func invalidatedReadNormalizesOrdinaryWorkerFailure(_ invalidation: ArtworkReadInvalidation) async throws {
        let fixture = try ArtworkReadFailureFixture()
        let task = Task { try await fixture.service.libraryArtwork(for: fixture.item) }
        defer { task.cancel(); fixture.reader.release() }
        try await fixture.reader.waitUntilReading()

        switch invalidation {
        case .replacement:
            fixture.item.artworkData = Data([2])
            try fixture.context.save()
        case .deletion:
            fixture.context.delete(fixture.item)
            try fixture.context.save()
        case .cancellation:
            task.cancel()
        }
        fixture.reader.release()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func currentReadPreservesOrdinaryWorkerFailure() async throws {
        let fixture = try ArtworkReadFailureFixture()
        let task = Task { try await fixture.service.libraryArtwork(for: fixture.item) }
        defer { task.cancel(); fixture.reader.release() }
        try await fixture.reader.waitUntilReading()
        fixture.reader.release()

        do {
            _ = try await task.value
            Issue.record("A current artwork read must preserve its worker error")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadNoSuchFile)
        }
    }
}

nonisolated private enum ArtworkReadInvalidation: CaseIterable {
    case replacement
    case deletion
    case cancellation
}

@MainActor
private struct ArtworkReadFailureFixture {
    let container: ModelContainer
    let context: ModelContext
    let item: MediaItem
    let service: LibraryService
    let reader: FailingArtworkReadProbe

    init() throws {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
        context = container.mainContext
        item = MediaItem(
            title: "Track", duration: 1, isVideo: false, bookmarkData: Data(),
            artworkData: Data([1]), fileName: "track.mp3"
        )
        context.insert(item)
        try context.save()
        reader = FailingArtworkReadProbe()
        service = LibraryService(artworkLoader: LibraryArtworkLoader(read: reader.read))
    }
}

nonisolated private final class FailingArtworkReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false

    func read(_ artworkID: UUID, _ container: ModelContainer) throws -> Data? {
        lock.withLock { started = true }
        guard gate.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        throw CocoaError(.fileReadNoSuchFile)
    }

    func release() { gate.signal() }

    func waitUntilReading() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while lock.withLock({ started }) == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(lock.withLock { started }, "The artwork reader did not start before the deadline")
    }
}

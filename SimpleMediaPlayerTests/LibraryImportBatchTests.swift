import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryImportBatchTests {
    enum Removal: CaseIterable { case delete, discardUnsaved }

    @Test(arguments: Removal.allCases)
    func queryMustContainLatestRegistrationAndCannotReuseBatchAfterRemoval(_ removal: Removal) async throws {
        let second = ImportRegistrationHold()
        let third = ImportRegistrationHold()
        let fourth = ImportRegistrationHold()
        let fixture = try InspectionFixture(recorder: ImportOperationRecorder(), beforeImportRegistration: { url in
            if url.lastPathComponent == "second.wav" { await second.hold(url) }
            if url.lastPathComponent == "third.wav" { await third.hold(url) }
            if url.lastPathComponent == "fourth.wav" { await fourth.hold(url) }
        })
        defer { fixture.remove() }
        defer { second.release(); third.release(); fourth.release() }
        let sources = try [
            fixture.makeAudio(named: "first.wav"),
            fixture.makeAudio(named: "second.wav", amplitude: 0.2),
            fixture.makeAudio(named: "third.wav", amplitude: 0.3),
            fixture.makeAudio(named: "fourth.wav", amplitude: 0.4)
        ]
        let service = fixture.service
        let context = fixture.context
        let task = Task {
            defer { second.taskEnded(); third.taskEnded(); fourth.taskEnded() }
            return await service.importFiles(from: sources, into: context, existingItems: [])
        }
        try #require(await second.waitUntilHeld())
        let firstQuery = try fixture.items()
        try #require(firstQuery.count == 1)
        let batch = try #require(service.importBatch(for: firstQuery, in: context))
        #expect(service.importBatch(for: firstQuery, in: ModelContext(fixture.container)) == nil)

        second.release()
        try #require(await third.waitUntilHeld())
        let query = FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.addedAt)])
        let items = try context.fetch(query)
        try #require(items.count == 2 && items.first === firstQuery.first)
        #expect(service.importBatch(for: firstQuery, in: context) == nil)
        #expect(service.importBatch(for: items, in: context) == batch)

        // Remove the older item, so even the stale array still ends in the latest registration.
        let removed = try #require(items.first)
        let cleanup = remove(removed, using: removal, fixture: fixture)
        #expect(service.importBatch(for: items, in: context) == nil)
        #expect(service.importBatch(for: Array(items.dropFirst()), in: context) == nil)
        third.release()
        try #require(await fourth.waitUntilHeld())
        let afterRemoval = try context.fetch(query)
        let nextBatch = try #require(service.importBatch(for: afterRemoval, in: context))
        #expect(nextBatch != batch)
        #expect(service.importBatch(for: items, in: context) == nil)
        fourth.release()
        let result = await task.value
        #expect(result.errors.isEmpty)
        let finalQuery = try context.fetch(query)
        #expect(service.importBatch(for: finalQuery, in: context) == nil)
        await cleanup?.value
    }

    private func remove(
        _ item: MediaItem, using method: Removal, fixture: InspectionFixture
    ) -> Task<Void, Never>? {
        switch method {
        case .delete:
            return fixture.service.delete(item, from: fixture.context)
        case .discardUnsaved:
            var summary = MediaImportSummary()
            fixture.service.discardUnsavedImports([item], from: fixture.context, summary: &summary)
            return nil
        }
    }
}

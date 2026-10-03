import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryListDeletionTests {
    @Test func selectionRejectsSavedDeletedPlaylistAndEntryBeforeTheQueryUpdates() async throws {
        let fixture = try LibraryListDeletionFixture()
        let projection = LibraryListProjection()
        defer { projection.cancel() }
        let betaID = fixture.beta.id
        projection.update(items: fixture.items, playlist: fixture.playlist, request: LibraryListRequest())
        try await waitUntil { projection.items.count == 2 }
        fixture.context.delete(fixture.firstEntry)
        try fixture.context.save()
        #expect(projection.selectedItem(id: fixture.alphaID) == nil)
        #expect(projection.selectedItem(id: betaID) === fixture.beta)
        fixture.context.delete(fixture.playlist)
        try fixture.context.save()
        #expect(projection.selectedItem(id: betaID) == nil)
    }

    @Test(arguments: [LibraryListDeletedModel.playlist, .entry])
    private func savedPlaylistOrEntryDeletionCannotPublishAnOldWorkerWithoutMetadataInvalidation(
        _ deletedModel: LibraryListDeletedModel
    ) async throws {
        let fixture = try LibraryListDeletionFixture()
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        let betaID = fixture.beta.id
        projection.update(items: fixture.items, playlist: fixture.playlist, request: LibraryListRequest())
        try await waitUntil { probe.count == 1 }
        if deletedModel == .playlist {
            fixture.context.delete(fixture.playlist)
        } else {
            fixture.context.delete(fixture.firstEntry)
        }
        try fixture.context.save()
        probe.finish(0, identifiers: [fixture.alphaID, betaID])
        let expected = deletedModel == .playlist ? [] : [betaID]
        try await Task.sleep(for: .milliseconds(10))
        #expect(projection.items.contains { $0.id == fixture.alphaID } == false)
        if deletedModel == .playlist { #expect(projection.items.isEmpty) }
        try await finishReplacementWorkers(probe, projection: projection, expected: expected)
        #expect(projection.items.map(\.id) == expected)
    }

    @Test func deletingOneOfTwoEntriesForTheSameItemPublishesOnlyTheSurvivingOccurrence() async throws {
        let fixture = try LibraryListDeletionFixture()
        let duplicate = PlaylistEntry(sortIndex: 2, playlist: fixture.playlist, item: fixture.alpha)
        fixture.playlist.entries.append(duplicate)
        try fixture.context.save()
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        let betaID = fixture.beta.id
        projection.update(items: fixture.items, playlist: fixture.playlist, request: LibraryListRequest())
        try await waitUntil { probe.count == 1 }
        fixture.context.delete(fixture.firstEntry)
        try fixture.context.save()
        probe.finish(0, identifiers: [fixture.alphaID, betaID, fixture.alphaID])
        try await Task.sleep(for: .milliseconds(10))
        #expect(projection.items.count <= 2)
        let expected = [betaID, fixture.alphaID]
        try await finishReplacementWorkers(probe, projection: projection, expected: expected)
        #expect(projection.items.map(\.id) == expected)
    }

    @Test(arguments: LibraryListDeletedModel.allCases)
    private func queuedSourceCaptureExcludesSavedDeletedModelsBeforeReadingTheirValues(
        _ deletedModel: LibraryListDeletedModel
    ) async throws {
        let fixture = try LibraryListDeletionFixture()
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        let playlist = deletedModel == .item ? nil : fixture.playlist
        projection.update(items: fixture.items, playlist: playlist, request: LibraryListRequest(sortField: .title))
        try await waitUntil { probe.count == 1 }

        // Queue the Observation refresh, then delete and save before MainActor yields.
        // @Query has not supplied its replacement array when the refresh copies models.
        fixture.beta.title = "Changed"
        switch deletedModel {
        case .item: fixture.context.delete(fixture.alpha)
        case .playlist: fixture.context.delete(fixture.playlist)
        case .entry: fixture.context.delete(fixture.firstEntry)
        }
        try fixture.context.save()
        try await waitUntil { probe.count == 2 }

        let expected = deletedModel == .playlist ? [] : [fixture.beta.id]
        #expect(probe.snapshot(at: 1).identifiers() == expected)
        probe.finish(1)
        try await waitUntil { projection.items.map(\.id) == expected }
        probe.finish(0, identifiers: [fixture.alphaID, fixture.beta.id])
        try await Task.sleep(for: .milliseconds(10))
        #expect(projection.items.map(\.id) == expected)
    }

    @Test func repeatedCapturePreservesRegistrationForDeletedModelsStillInStaleInputs() async throws {
        let fixture = try LibraryListDeletionFixture()
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: fixture.items, playlist: nil, request: LibraryListRequest())
        try await waitUntil { probe.count == 1 }
        fixture.beta.title = "Changed"
        fixture.context.delete(fixture.alpha)
        try fixture.context.save()
        try await waitUntil { probe.count == 2 }
        #expect(probe.snapshot(at: 1).items.map(\.id) == [fixture.beta.id])

        fixture.beta.title = "Changed Again"
        try await waitUntil { probe.count == 3 }
        #expect(probe.snapshot(at: 2).items.map(\.id) == [fixture.beta.id])
        probe.finish(2)
        try await waitUntil { projection.items.map(\.id) == [fixture.beta.id] }
        #expect(projection.selectedItem(id: fixture.alphaID) == nil)
    }

    @Test func replacingSourceRemovesOldObservationAndUsesNewModelReferences() async throws {
        let fixture = try LibraryListDeletionFixture()
        let probe = LibraryListComputationProbe()
        let projection = LibraryListProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [fixture.alpha], playlist: nil, request: LibraryListRequest())
        try await waitUntil { probe.count == 1 }
        projection.update(items: [fixture.beta], playlist: nil, request: LibraryListRequest())
        try await waitUntil { probe.count == 2 }
        fixture.alpha.title = "Changed Outside The Current Source"
        try await Task.sleep(for: .milliseconds(10))
        #expect(probe.count == 2)
        probe.finish(1)
        try await waitUntil { projection.items.map(\.id) == [fixture.beta.id] }
        #expect(projection.selectedItem(id: fixture.beta.id) === fixture.beta)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while condition() == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition(), "The list deletion computation did not reach the expected state")
    }

    private func finishReplacementWorkers(
        _ probe: LibraryListComputationProbe, projection: LibraryListProjection, expected: [UUID]
    ) async throws {
        var nextWorker = 1
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            // Relationship changes may send an Observation callback even when deletion
            // does not change the item's metadata. Finish any resulting fresh worker.
            while nextWorker < probe.count {
                probe.finish(nextWorker)
                nextWorker += 1
            }
            if projection.items.map(\.id) == expected { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(projection.items.map(\.id) == expected)
    }
}

nonisolated private enum LibraryListDeletedModel: CaseIterable {
    case item, playlist, entry
}

@MainActor
private struct LibraryListDeletionFixture {
    let container: ModelContainer
    let alpha: MediaItem
    let beta: MediaItem
    let alphaID: UUID
    let playlist: Playlist
    let firstEntry: PlaylistEntry
    var context: ModelContext { container.mainContext }
    var items: [MediaItem] { [alpha, beta] }

    init() throws {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
        alpha = MediaItem(title: "Alpha", duration: 1, isVideo: false, bookmarkData: Data(), fileName: "alpha.mp3")
        beta = MediaItem(title: "Beta", duration: 1, isVideo: false, bookmarkData: Data(), fileName: "beta.mp3")
        alphaID = alpha.id
        playlist = Playlist(name: "Playlist")
        firstEntry = PlaylistEntry(sortIndex: 0, playlist: playlist, item: alpha)
        playlist.entries = [firstEntry, PlaylistEntry(sortIndex: 1, playlist: playlist, item: beta)]
        container.mainContext.insert(playlist)
        container.mainContext.insert(alpha)
        container.mainContext.insert(beta)
        try container.mainContext.save()
    }
}

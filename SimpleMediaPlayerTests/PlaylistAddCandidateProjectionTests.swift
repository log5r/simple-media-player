import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct PlaylistAddCandidateProjectionTests {
    @Test func sourceSelectionAndFocusReadsDoNotRecaptureOrRecompute() async throws {
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let source = [alpha, beta]
        let playlist = Playlist(name: "Playlist")
        playlist.entries = [PlaylistEntry(sortIndex: 0, playlist: playlist, item: alpha)]
        let probe = PlaylistAddComputationProbe()
        let projection = PlaylistAddCandidateProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: source, playlist: playlist)
        try await waitUntil { probe.count == 1 }
        probe.finish(0)
        try await waitUntil { projection.items.count == 1 }

        for _ in 0..<50 {
            projection.update(items: source, playlist: playlist)
            projection.update(searchText: "")
            _ = projection.items
            _ = projection.isUpdating
            #expect(projection.selectedItems(ids: [beta.id], for: playlist)?.first === beta)
        }
        #expect(probe.count == 1)
        #expect(probe.wasMainThread == false)
        projection.update(searchText: "beta")
        try await waitUntil { probe.count == 2 }
        #expect(probe.snapshot(at: 0).sourceGeneration == probe.snapshot(at: 1).sourceGeneration)
        #expect(probe.snapshot(at: 1).excludedIDs == [alpha.id])
        alpha.lyricsRaw = "Changed lyrics"
        alpha.artworkData = Data([1])
        try await Task.sleep(for: .milliseconds(10))
        #expect(probe.count == 2)
    }

    @Test func newestSearchWinsWhenOldWorkersIgnoreCancellation() async throws {
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let playlist = Playlist(name: "Playlist")
        let probe = PlaylistAddComputationProbe()
        let projection = PlaylistAddCandidateProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(searchText: "alpha")
        projection.update(items: [alpha, beta], playlist: playlist)
        try await waitUntil { probe.count == 1 }
        let oldCompletion = try #require(projection.pendingCompletion)
        projection.update(searchText: "beta")
        try await waitUntil { probe.count == 2 }
        probe.finish(1)
        try await waitUntil { projection.items.map(\.id) == [beta.id] }
        probe.finish(0, identifiers: [alpha.id])
        await oldCompletion.value
        #expect(projection.items.map(\.id) == [beta.id])
        projection.update(searchText: "")
        try await waitUntil { probe.count == 3 }
        probe.finish(2)
        try await waitUntil { projection.items.map(\.id) == [alpha.id, beta.id] }
        #expect(probe.snapshot(at: 2).sourceGeneration == probe.snapshot(at: 0).sourceGeneration)
    }

    @Test func metadataWillSetRejectsAnAlreadyQueuedOldCompletion() async throws {
        let item = makeItem("Alpha")
        let playlist = Playlist(name: "Playlist")
        let probe = PlaylistAddComputationProbe()
        let projection = PlaylistAddCandidateProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(searchText: "alpha")
        projection.update(items: [item], playlist: playlist)
        try await waitUntil { probe.count == 1 }
        let oldCompletion = try #require(projection.pendingCompletion)
        probe.finish(0, identifiers: [item.id])
        item.title = "Beta"
        projection.update(searchText: "beta")
        await oldCompletion.value
        try await waitUntil { probe.count == 2 }
        #expect(projection.items.isEmpty)
        #expect(probe.query(at: 1) == "beta")
        #expect(probe.snapshot(at: 1).items.first?.title == "Beta")
        probe.finish(1)
        try await waitUntil { projection.items.first === item }
    }

    @Test(arguments: PlaylistAddObservedField.allCases)
    func searchFieldsInvalidateTheirFrozenSource(_ field: PlaylistAddObservedField) async throws {
        let item = makeItem("Alpha")
        let playlist = Playlist(name: "Playlist")
        let probe = PlaylistAddComputationProbe()
        let projection = PlaylistAddCandidateProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [item], playlist: playlist)
        try await waitUntil { probe.count == 1 }
        field.change(item)
        try await waitUntil { probe.count == 2 }
        #expect(probe.snapshot(at: 0).sourceGeneration != probe.snapshot(at: 1).sourceGeneration)
        probe.finish(1)
        try await waitUntil { projection.items.map(\.id) == [item.id] }
    }

    @Test(arguments: PlaylistAddEntryChange.allCases)
    func playlistMembershipChangesUpdateExclusions(_ change: PlaylistAddEntryChange) async throws {
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let playlist = Playlist(name: "Playlist")
        let entry = PlaylistEntry(sortIndex: 0, playlist: playlist, item: alpha)
        playlist.entries = [entry]
        let probe = PlaylistAddComputationProbe()
        let projection = PlaylistAddCandidateProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [alpha, beta], playlist: playlist)
        try await waitUntil { probe.count == 1 }
        let oldCompletion = try #require(projection.pendingCompletion)
        switch change {
        case .insert: playlist.entries.append(PlaylistEntry(sortIndex: 1, playlist: playlist, item: beta))
        case .remove: playlist.entries.removeAll()
        case .relationship: entry.item = beta
        }
        try await waitUntil { probe.count == 2 }
        let newCompletion = try #require(projection.pendingCompletion)
        probe.finish(1)
        await newCompletion.value
        let expected = change == .insert ? [] : change == .remove ? [alpha.id, beta.id] : [alpha.id]
        #expect(projection.items.map(\.id) == expected)
        probe.finish(0, identifiers: [beta.id])
        await oldCompletion.value
        #expect(projection.items.map(\.id) == expected)
    }

    @Test func replacingSameCountModelsAndPlaylistRejectsTheirOldResult() async throws {
        let alpha = makeItem("Alpha")
        let replacement = makeItem("Replacement")
        replacement.id = alpha.id
        let first = Playlist(name: "First")
        let second = Playlist(name: "Second")
        let probe = PlaylistAddComputationProbe()
        let projection = PlaylistAddCandidateProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: [alpha], playlist: first)
        try await waitUntil { probe.count == 1 }
        let firstCompletion = try #require(projection.pendingCompletion)
        projection.update(items: [replacement], playlist: first)
        try await waitUntil { probe.count == 2 }
        let secondCompletion = try #require(projection.pendingCompletion)
        #expect(probe.snapshot(at: 1).items.first?.title == "Replacement")
        projection.update(items: [replacement], playlist: second)
        try await waitUntil { probe.count == 3 }
        #expect(projection.selectedItems(ids: [alpha.id], for: first) == nil)
        probe.finish(2)
        try await waitUntil { projection.items.first === replacement }
        probe.finish(0)
        probe.finish(1)
        await firstCompletion.value
        await secondCompletion.value
        #expect(projection.items.first === replacement)
    }

    @Test func sourceInsertionRemovalAndOrderChangesAreApplied() async throws {
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let playlist = Playlist(name: "Playlist")
        let projection = PlaylistAddCandidateProjection()
        defer { projection.cancel() }
        projection.update(items: [alpha], playlist: playlist)
        try await waitUntil { projection.items.count == 1 }
        projection.update(items: [beta, alpha], playlist: playlist)
        try await waitUntil { projection.items.map(\.id) == [beta.id, alpha.id] }
        projection.update(items: [beta], playlist: playlist)
        try await waitUntil { projection.items.map(\.id) == [beta.id] }
    }

    @Test func hiddenSelectionsKeepSourceOrderAndDiacriticMatching() async throws {
        let accented = makeItem("Café")
        let plain = makeItem("Cafe")
        let playlist = Playlist(name: "Playlist")
        let projection = PlaylistAddCandidateProjection()
        defer { projection.cancel() }
        projection.update(items: [accented, plain], playlist: playlist)
        projection.update(searchText: "CAFE")
        try await waitUntil { projection.items.map(\.id) == [plain.id] }
        let selected = projection.selectedItems(ids: [plain.id, accented.id], for: playlist)
        #expect(selected?.map(\.id) == [accented.id, plain.id])
        projection.update(searchText: "CAFÉ")
        try await waitUntil { projection.items.map(\.id) == [accented.id] }
        projection.update(searchText: "")
        try await waitUntil { projection.items.count == 2 }
    }

    @Test func disappearingRejectsCompletionAndReappearingCapturesAgain() async throws {
        let alpha = makeItem("Alpha")
        let beta = makeItem("Beta")
        let playlist = Playlist(name: "Playlist")
        let probe = PlaylistAddComputationProbe()
        let projection = PlaylistAddCandidateProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(searchText: "beta")
        projection.update(items: [alpha, beta], playlist: playlist)
        try await waitUntil { probe.count == 1 }
        let oldCompletion = try #require(projection.pendingCompletion)
        projection.cancel()
        probe.finish(0)
        alpha.title = "Changed after closing"
        await oldCompletion.value
        #expect(projection.items.isEmpty && probe.count == 1)
        #expect(projection.selectedItems(ids: [beta.id], for: playlist) == nil)
        projection.update(items: [alpha, beta], playlist: playlist)
        try await waitUntil { probe.count == 2 }
        #expect(probe.snapshot(at: 1).sourceGeneration != probe.snapshot(at: 0).sourceGeneration)
        probe.finish(1)
        try await waitUntil { projection.items.map(\.id) == [beta.id] }
    }

    @Test func cancelledFilteringStopsReadingRemainingValues() async {
        let counter = PlaylistAddCancellationCounter()
        let values = (0..<10_000).map { _ in PlaylistAddCancellationItem(counter: counter) }
        let result = await Task.detached {
            PlaylistAddCandidateFilter.candidates(from: values, excluding: [], searchText: "absent")
        }.value
        #expect(result.isEmpty)
        #expect(counter.reads == 50)
    }

    private func makeItem(_ title: String) -> MediaItem {
        MediaItem(title: title, duration: 1, isVideo: false, bookmarkData: Data(), fileName: "song.mp3")
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while predicate() == false {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

extension PlaylistAddCandidateProjectionTests {
    @Test(arguments: PlaylistAddDeletedModel.allCases)
    func savedDeletionCannotReviveOldCandidatesOrSupplyDeletedSelections(
        _ deleted: PlaylistAddDeletedModel
    ) async throws {
        let fixture = try PlaylistAddDeletionFixture()
        let probe = PlaylistAddComputationProbe()
        let projection = PlaylistAddCandidateProjection(compute: probe.compute)
        defer { projection.cancel(); probe.finishAll() }
        projection.update(items: fixture.items, playlist: fixture.playlist)
        try await waitUntil { probe.count == 1 }
        switch deleted {
        case .item: fixture.context.delete(fixture.beta)
        case .entry: fixture.context.delete(fixture.entry)
        case .playlist: fixture.context.delete(fixture.playlist)
        }
        try fixture.context.save()
        if deleted == .playlist {
            #expect(projection.selectedItems(ids: [fixture.betaID], for: fixture.playlist) == nil)
        } else if deleted == .item {
            #expect(projection.selectedItems(ids: [fixture.betaID], for: fixture.playlist)?.isEmpty != false)
        }
        probe.finish(0, identifiers: [fixture.alphaID, fixture.betaID])
        let expected = deleted == .entry ? [fixture.alphaID, fixture.betaID] : []
        // A saved item deletion can clear modelContext without an observation callback.
        // Both direct validation of the old result and a recaptured source must reject it.
        try await waitUntil { probe.count >= 2 || projection.isUpdating == false }
        if probe.count >= 2 {
            probe.finish(1, identifiers: expected)
        }
        try await waitUntil { projection.isUpdating == false }
        #expect(projection.items.map(\.id) == expected)
    }

    @Test func savedDeletedSelectionIsRejectedBeforeAQueryArrayReplacement() async throws {
        let fixture = try PlaylistAddDeletionFixture()
        let projection = PlaylistAddCandidateProjection()
        defer { projection.cancel() }
        projection.update(items: fixture.items, playlist: fixture.playlist)
        try await waitUntil { projection.items.map(\.id) == [fixture.betaID] }
        fixture.context.delete(fixture.beta)
        try fixture.context.save()
        // @Query still holds the old array, but an Add callback must never receive this detached model.
        #expect(projection.selectedItems(ids: [fixture.betaID], for: fixture.playlist)?.isEmpty != false)
        fixture.context.delete(fixture.playlist)
        try fixture.context.save()
        // nil tells the view not to invoke addItems at all, even with an empty array.
        #expect(projection.selectedItems(ids: [fixture.betaID], for: fixture.playlist) == nil)
    }
}

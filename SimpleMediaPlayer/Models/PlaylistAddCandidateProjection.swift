import Foundation
import Observation
import SwiftData

/// The sheet observes models when its source changes; typing searches only frozen values.
@MainActor
@Observable
final class PlaylistAddCandidateProjection {
    private(set) var items: [MediaItem] = []
    private(set) var isUpdating = false

    @ObservationIgnored private var source: Source?
    @ObservationIgnored private var searchText = ""
    @ObservationIgnored private var snapshot: PlaylistAddCandidateSnapshot?
    @ObservationIgnored private var sourceByID: [UUID: MediaItem] = [:]
    @ObservationIgnored private var sourceOrder: [UUID] = []
    @ObservationIgnored private var registeredModels: [ObjectIdentifier: any PersistentModel] = [:]
    @ObservationIgnored private var visibleIDs: [UUID] = []
    @ObservationIgnored private let sourceGeneration = LibraryListGeneration()
    @ObservationIgnored private let observationLifetime = LibraryListObservationLifetime()
    @ObservationIgnored private var requestGeneration: UInt64 = 0
    @ObservationIgnored private var worker: Task<[UUID], Never>?
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private let compute: @Sendable (PlaylistAddCandidateSnapshot, String) async -> [UUID]

    init(
        compute: @escaping @Sendable (PlaylistAddCandidateSnapshot, String) async -> [UUID] = {
            $0.identifiers(searchText: $1)
        }
    ) {
        self.compute = compute
    }

    deinit {
        worker?.cancel()
        completion?.cancel()
    }

    func update(items: [MediaItem], playlist: Playlist) {
        let next = Source(items: items, playlist: playlist)
        if source == next, let snapshot, sourceGeneration.isCurrent(snapshot.sourceGeneration) { return }
        if source?.playlist !== playlist {
            self.items = []
            visibleIDs = []
        }
        source = next
        captureSource()
    }

    func update(searchText: String) {
        guard self.searchText != searchText else { return }
        self.searchText = searchText
        // A model's willSet already invalidated the source and queued a fresh capture.
        // Leave that capture to read the finished setter rather than rereading models here.
        startComputation()
    }

    /// Hidden search selections survive, but deleted models and a superseded playlist never reach Add.
    func selectedItems(ids: Set<UUID>, for playlist: Playlist) -> [MediaItem]? {
        guard let source, source.playlist === playlist, isAvailable(playlist),
              let snapshot, sourceGeneration.isCurrent(snapshot.sourceGeneration) else { return nil }
        return sourceOrder.compactMap { id in
            guard ids.contains(id), let item = sourceByID[id], isAvailable(item) else { return nil }
            return item
        }
    }

    func cancel() {
        sourceGeneration.advance()
        observationLifetime.revision &+= 1
        requestGeneration &+= 1
        worker?.cancel()
        completion?.cancel()
        worker = nil
        completion = nil
        source = nil
        snapshot = nil
        sourceByID = [:]
        sourceOrder = []
        registeredModels = [:]
        visibleIDs = []
        items = []
        isUpdating = false
    }

    private func captureSource() {
        guard let source else { return }
        let generation = sourceGeneration.advance()
        // Retire the one-shot observer even when the replaced models never change again.
        observationLifetime.revision &+= 1
        let generationState = sourceGeneration
        let captured = withObservationTracking {
            _ = observationLifetime.revision
            return makeSnapshot(source, generation: generation)
        } onChange: { [weak self] in
            guard let invalidation = generationState.invalidate(ifCurrent: generation) else { return }
            Task { @MainActor [weak self] in
                guard let self, generationState.isCurrent(invalidation), self.source != nil else { return }
                self.captureSource()
            }
        }
        snapshot = captured.snapshot
        sourceByID = captured.references
        sourceOrder = captured.snapshot.items.map(\.id)
        registeredModels = captured.registrations
        publish(visibleIDs)
        startComputation()
    }

    private func makeSnapshot(_ source: Source, generation: UInt64) -> CapturedSource {
        var registrations: [ObjectIdentifier: any PersistentModel] = [:]
        var excludedIDs: Set<UUID> = []
        if registerIfAvailable(source.playlist, registrations: &registrations) {
            for entry in source.playlist.entries where registerIfAvailable(entry, registrations: &registrations) {
                if let item = entry.item, registerIfAvailable(item, registrations: &registrations) {
                    excludedIDs.insert(item.id)
                }
            }
        }
        var references: [UUID: MediaItem] = [:]
        let values = source.items.compactMap { item -> PlaylistAddCandidateSnapshot.Item? in
            guard registerIfAvailable(item, registrations: &registrations) else { return nil }
            let value = PlaylistAddCandidateSnapshot.Item(item: item)
            references[value.id] = item
            return value
        }
        return CapturedSource(
            snapshot: PlaylistAddCandidateSnapshot(
                items: values, excludedIDs: excludedIDs, sourceGeneration: generation
            ),
            references: references, registrations: registrations
        )
    }

    private func startComputation() {
        requestGeneration &+= 1
        let request = requestGeneration
        worker?.cancel()
        completion?.cancel()
        guard let snapshot, sourceGeneration.isCurrent(snapshot.sourceGeneration), source != nil else { return }
        let query = searchText
        let compute = compute
        isUpdating = true
        let operation = Task.detached(priority: .userInitiated) { await compute(snapshot, query) }
        worker = operation
        completion = Task { [weak self] in
            let identifiers = await operation.value
            guard Task.isCancelled == false, let self,
                  self.requestGeneration == request,
                  self.sourceGeneration.isCurrent(snapshot.sourceGeneration) else { return }
            self.publish(identifiers)
            self.worker = nil
            self.completion = nil
            self.isUpdating = false
        }
    }

    /// Validation reads model liveness only; it never rereads search metadata or playlist entries.
    private func publish(_ identifiers: [UUID]) {
        guard let playlist = source?.playlist, isAvailable(playlist), let snapshot else {
            items = []
            visibleIDs = []
            return
        }
        var values: [MediaItem] = []
        var liveIDs: [UUID] = []
        for id in identifiers {
            guard snapshot.excludedIDs.contains(id) == false,
                  let item = sourceByID[id], isAvailable(item) else { continue }
            liveIDs.append(id)
            values.append(item)
        }
        visibleIDs = liveIDs
        items = values
    }

    private func isAvailable(_ model: any PersistentModel) -> Bool {
        model.isDeleted == false
            && (registeredModels[ObjectIdentifier(model)] == nil || model.modelContext != nil)
    }

    private func registerIfAvailable(
        _ model: any PersistentModel, registrations: inout [ObjectIdentifier: any PersistentModel]
    ) -> Bool {
        let identity = ObjectIdentifier(model)
        let wasRegistered = registeredModels[identity] != nil
        if wasRegistered || model.modelContext != nil { registrations[identity] = model }
        return model.isDeleted == false && (wasRegistered == false || model.modelContext != nil)
    }

    private struct CapturedSource {
        let snapshot: PlaylistAddCandidateSnapshot
        let references: [UUID: MediaItem]
        let registrations: [ObjectIdentifier: any PersistentModel]
    }

    nonisolated struct Source: Equatable {
        let items: [MediaItem]
        let playlist: Playlist

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.playlist === rhs.playlist, lhs.items.count == rhs.items.count else { return false }
            // Both pointers remain valid together and neither array is mutated in these scopes.
            // Equal addresses and counts prove shared storage; different storage still compares every reference.
            let sharesStorage = lhs.items.withUnsafeBufferPointer { left in
                rhs.items.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
            }
            return sharesStorage || lhs.items.elementsEqual(rhs.items) { $0 === $1 }
        }
    }
}

extension PlaylistAddCandidateProjection {
    /// Includes result validation and publication, even when a replaced worker ignores cancellation.
    var pendingCompletion: Task<Void, Never>? { completion }
}

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LibraryListProjection {
    private(set) var items: [MediaItem] = []

    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var snapshot: LibraryListSnapshot?
    @ObservationIgnored private var sourceByID: [UUID: MediaItem] = [:]
    @ObservationIgnored private var sourceEntriesByID: [UUID: PlaylistEntry] = [:]
    @ObservationIgnored private var registeredModels: [ObjectIdentifier: any PersistentModel] = [:]
    @ObservationIgnored private var visibleByID: [UUID: MediaItem] = [:]
    @ObservationIgnored private var visibleEntriesByID: [UUID: [PlaylistEntry]] = [:]
    @ObservationIgnored private var visibleIDs: [UUID] = []
    @ObservationIgnored private var visibleEntryIDs: [UUID?]?
    @ObservationIgnored private let sourceGeneration = LibraryListGeneration()
    @ObservationIgnored private let observationLifetime = LibraryListObservationLifetime()
    @ObservationIgnored private var observedGeneration: UInt64 = 0
    @ObservationIgnored private var requestGeneration: UInt64 = 0
    @ObservationIgnored private var worker: Task<LibraryListResult, Never>?
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private let compute: @Sendable (LibraryListSnapshot) async -> [UUID]

    init(compute: @escaping @Sendable (LibraryListSnapshot) async -> [UUID] = { $0.identifiers() }) {
        self.compute = compute
    }

    deinit {
        worker?.cancel()
        completion?.cancel()
    }

    func selectedItem(id: UUID) -> MediaItem? {
        // Register the same dependency as list/count/queue consumers.
        _ = items
        guard let item = visibleByID[id], isAvailable(item) else { return nil }
        if let playlist = inputs?.playlist {
            guard isAvailable(playlist),
                  visibleEntriesByID[id]?.contains(where: isAvailable) == true else { return nil }
        }
        return item
    }

    func update(items: [MediaItem], playlist: Playlist?, request: LibraryListRequest) {
        let sameSource = inputs?.hasSameSource(items: items, playlist: playlist) == true
        let sourceIsCurrent = sameSource && sourceGeneration.isCurrent(observedGeneration)
        if sourceIsCurrent, inputs?.request == request { return }
        clearItemsIfDestinationChanged(playlist: playlist, request: request)
        inputs = Inputs(items: items, playlist: playlist, request: request)
        if sourceIsCurrent {
            startComputation()
        } else {
            captureSource()
        }
    }

    /// Query changes reuse the observed metadata snapshot without scanning model references.
    func update(request: LibraryListRequest) {
        guard let inputs else { return }
        if inputs.request == request, sourceGeneration.isCurrent(observedGeneration) { return }
        clearItemsIfDestinationChanged(playlist: inputs.playlist, request: request)
        self.inputs?.request = request
        if sourceGeneration.isCurrent(observedGeneration) {
            startComputation()
        } else {
            captureSource()
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
        inputs = nil
        snapshot = nil
        sourceByID = [:]
        sourceEntriesByID = [:]
        registeredModels = [:]
        publish(LibraryListResult(identifiers: []))
    }

    private func clearItemsIfDestinationChanged(playlist: Playlist?, request: LibraryListRequest) {
        guard let inputs,
              inputs.playlist !== playlist || inputs.request.section != request.section else { return }
        items = []
        visibleByID = [:]
        visibleEntriesByID = [:]
        visibleIDs = []
        visibleEntryIDs = nil
    }

    private func captureSource() {
        guard let inputs else { return }
        let generation = sourceGeneration.advance()
        // Fire the previous one-shot tracker after invalidating its token. This removes
        // its model subscriptions even when the replaced source itself never changes.
        observationLifetime.revision &+= 1
        observedGeneration = generation
        let generationState = sourceGeneration
        let captured = withObservationTracking {
            _ = observationLifetime.revision
            return makeSnapshot(inputs)
        } onChange: { [weak self] in
            // Observation fires before the model setter finishes. Invalidate synchronously so
            // an already completed worker cannot publish while the MainActor refresh is queued.
            guard let invalidation = generationState.invalidate(ifCurrent: generation) else { return }
            Task { @MainActor [weak self] in
                guard let self, generationState.isCurrent(invalidation), self.inputs != nil else { return }
                self.captureSource()
            }
        }
        snapshot = captured.snapshot
        sourceByID = captured.references
        sourceEntriesByID = captured.entriesByID
        registeredModels = captured.registrations
        // Relationship deletion may precede a new worker result; never expose removed models.
        publish(LibraryListResult(identifiers: visibleIDs, entryIDs: visibleEntryIDs))
        startComputation()
    }

    private func makeSnapshot(_ inputs: Inputs) -> CapturedSource {
        var playlistEntries: [LibraryListPlaylistEntrySnapshot]?
        var registrations: [ObjectIdentifier: any PersistentModel] = [:]
        var entriesByID: [UUID: PlaylistEntry] = [:]
        // Register before reading IDs/metadata. Saved deletions clear their context and
        // reset isDeleted, so preserve the registration of models still in stale inputs.
        let libraryItems = inputs.items.filter { registerIfAvailable($0, registrations: &registrations) }
        let source: [MediaItem]
        if let playlist = inputs.playlist {
            let libraryIDs = Set(libraryItems.map(\.id))
            let entries = registerIfAvailable(playlist, registrations: &registrations)
                ? playlist.entries.filter { registerIfAvailable($0, registrations: &registrations) } : []
            var playlistItems: [MediaItem] = []
            playlistEntries = entries.map { entry in
                let item = entry.item.flatMap { candidate in
                    registerIfAvailable(candidate, registrations: &registrations) ? candidate : nil
                }
                if let item, libraryIDs.contains(item.id) {
                    playlistItems.append(item)
                    entriesByID[entry.id] = entry
                }
                return LibraryListPlaylistEntrySnapshot(id: entry.id, sortIndex: entry.sortIndex, itemID: item?.id)
            }
            source = playlistItems
        } else {
            source = libraryItems
        }
        var references: [UUID: MediaItem] = [:]
        let values = source.map { item in
            references[item.id] = item
            return LibraryListItemSnapshot(item: item)
        }
        return CapturedSource(
            snapshot: LibraryListSnapshot(items: values, playlistEntries: playlistEntries, request: inputs.request),
            references: references, registrations: registrations, entriesByID: entriesByID
        )
    }

    private func startComputation() {
        guard let inputs, let snapshot else { return }
        requestGeneration &+= 1
        let request = requestGeneration
        let source = observedGeneration
        worker?.cancel()
        completion?.cancel()
        let compute = compute
        let values = snapshot.with(request: inputs.request)
        let operation = Task.detached(priority: .userInitiated) {
            values.result(identifiers: await compute(values))
        }
        worker = operation
        completion = Task { [weak self] in
            let result = await operation.value
            guard Task.isCancelled == false, let self,
                  self.requestGeneration == request,
                  self.sourceGeneration.isCurrent(source) else { return }
            self.publish(result)
            self.worker = nil
            self.completion = nil
        }
    }

    private func publish(_ result: LibraryListResult) {
        visibleByID = [:]
        visibleEntriesByID = [:]
        visibleIDs = []
        visibleEntryIDs = result.entryIDs == nil ? nil : []
        var values: [MediaItem] = []
        let playlistIsAvailable = inputs?.playlist.map(isAvailable) ?? true
        for (index, id) in result.identifiers.enumerated() {
            guard playlistIsAvailable, let item = sourceByID[id], isAvailable(item) else { continue }
            let entryID = result.entryIDs?[index]
            if inputs?.playlist != nil {
                guard let entryID, let entry = sourceEntriesByID[entryID], isAvailable(entry) else { continue }
                visibleEntriesByID[id, default: []].append(entry)
            }
            visibleIDs.append(id)
            visibleEntryIDs?.append(entryID)
            visibleByID[id] = item
            values.append(item)
        }
        items = values
    }

    private func isAvailable(_ model: any PersistentModel) -> Bool {
        model.isDeleted == false
            && (registeredModels[ObjectIdentifier(model)] == nil || model.modelContext != nil)
    }

    private func registerIfAvailable(
        _ model: any PersistentModel,
        registrations: inout [ObjectIdentifier: any PersistentModel]
    ) -> Bool {
        let identity = ObjectIdentifier(model)
        let wasRegistered = registeredModels[identity] != nil
        if wasRegistered || model.modelContext != nil { registrations[identity] = model }
        return model.isDeleted == false && (wasRegistered == false || model.modelContext != nil)
    }

    private struct CapturedSource {
        let snapshot: LibraryListSnapshot
        let references: [UUID: MediaItem]
        let registrations: [ObjectIdentifier: any PersistentModel]
        let entriesByID: [UUID: PlaylistEntry]
    }

    private struct Inputs {
        let items: [MediaItem]
        let playlist: Playlist?
        var request: LibraryListRequest

        func hasSameSource(items: [MediaItem], playlist: Playlist?) -> Bool {
            self.playlist === playlist && self.items.count == items.count
                && zip(self.items, items).allSatisfy { $0 === $1 }
        }
    }
}

@MainActor
@Observable
private final class LibraryListObservationLifetime {
    var revision: UInt64 = 0
}

/// Only the generation counter is shared with Observation's synchronous callback.
/// Its lock never encloses model reads, snapshot work, or result publication.
nonisolated private final class LibraryListGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    @discardableResult
    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func invalidate(ifCurrent expected: UInt64) -> UInt64? {
        lock.withLock {
            guard value == expected else { return nil }
            value &+= 1
            return value
        }
    }

    func isCurrent(_ expected: UInt64) -> Bool {
        lock.withLock { value == expected }
    }
}

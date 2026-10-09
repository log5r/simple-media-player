import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension MainView {
    func deleteLibraryItem(_ item: MediaItem) {
        if player.currentItem?.id == item.id {
            player.clearCurrentItem()
        }
        player.queue.removeAll { $0.id == item.id }
        libraryService.delete(item, from: modelContext)
    }

    func remove(_ item: MediaItem, from playlist: Playlist) {
        for entry in playlist.entries where entry.item?.id == item.id {
            modelContext.delete(entry)
        }
        normalizeSortIndexes(for: playlist)
        save()
    }

    func move(_ source: IndexSet, to destination: Int, in playlist: Playlist) {
        playlist.moveItems(fromOffsets: source, toOffset: destination)
        save()
    }

    var selectedSection: LibrarySection? {
        if browsingState.phoneTab == 3 { return nil }
        guard case let .library(section) = selection else { return nil }
        return section
    }

    var selectedPlaylist: Playlist? {
        guard case let .playlist(id) = selection else { return nil }
        return playlists.first { $0.id == id }
    }

    var navigationTitle: String {
        if browsingState.phoneTab == 3 { return L10n.string("Search") }
        if let group = browsingState.group { return group.name }
        return switch selection {
        case let .library(section):
            section.title
        case let .playlist(id):
            playlists.first { $0.id == id }?.name ?? L10n.string("Playlists")
        }
    }

    var filteredItems: [MediaItem] {
        listProjection.items
    }

    var browsingPlaybackQueue: [MediaItem] {
        browsingState.playbackQueue(from: filteredItems)
    }

    func playBrowsingItem(_ item: MediaItem) {
        let queue = browsingPlaybackQueue
        guard item.isDeleted == false, queue.contains(where: { $0.id == item.id }) else { return }
        browsingState.selectedItemID = item.id
        browsingState.playingListName = navigationTitle
        player.play(item: item, in: queue)
    }

    var selectedItem: MediaItem? {
        guard let selectedItemID else { return nil }
        guard let item = listProjection.selectedItem(id: selectedItemID),
              browsingState.group?.contains(item) != false else { return nil }
        return item
    }

    var canCreateAACVersion: Bool {
        !isSharingExport && !isPreparingExport && pendingExportPlan == nil
            && namedExportRequest == nil && aacVersionSourceTitle == nil
            && aacVersionExporter.isExporting == false
            && libraryService.isImporting == false
            && libraryService.isExporting == false
    }

    private var isSharingExport: Bool {
        #if os(iOS)
        phoneExportSheet != nil
        #else
        false
        #endif
    }

    func startImport(_ urls: [URL], retainingSecurityScopedAccess: Bool = false) {
        let accessedURLs = retainingSecurityScopedAccess
            ? urls.filter { $0.startAccessingSecurityScopedResource() }
            : []

        Task {
            defer {
                accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            await libraryService.importFiles(from: urls, into: modelContext, existingItems: items)
            importErrorPresented = libraryService.lastImportErrors.isEmpty == false
        }
    }

    func startFinderExport() {
        startExport(browsingPlaybackQueue)
    }

    func startExport(_ exportItems: [MediaItem]) {
        #if os(iOS)
        if let sharedExportSession, !sharedExportSession.isCompleted {
            phoneExportSheet = .share(sharedExportSession)
            return
        }
        #endif
        guard canCreateAACVersion else { return }
        isPreparingExport = true
        Task {
            defer { isPreparingExport = false }
            guard let plan = try? await libraryService.makeExportPlan(for: exportItems) else { return }
            guard plan.files.isEmpty == false else {
                exportResultMessage = plan.preparationErrors.isEmpty
                    ? L10n.string("No media selected for export.")
                    : plan.preparationErrors.joined(separator: "\n")
                exportResultPresented = true
                return
            }

            if plan.missingTitleFiles.isEmpty {
                await exportToFinder(plan: plan, nameOverrides: [:])
            } else {
                #if os(iOS)
                phoneExportSheet = .names(plan)
                #else
                pendingExportPlan = plan
                #endif
            }
        }
    }

    func createAACVersion(of item: MediaItem) {
        exportAACVersion(of: item)
    }

    func exportAACVersion(of item: MediaItem) {
        guard item.isVideo == false, canCreateAACVersion else { return }

        let sourceTitle = item.title
        aacVersionSourceTitle = sourceTitle
        Task {
            defer { aacVersionSourceTitle = nil }

            do {
                _ = try await aacVersionExporter.export(
                    item: item,
                    title: sourceTitle,
                    format: .aac,
                    pitchSemitones: 0,
                    rate: 1,
                    libraryService: libraryService,
                    context: modelContext
                )
                aacVersionResultMessage = L10n.format("Created an AAC version of “%@”.", sourceTitle)
            } catch is CancellationError {
                return
            } catch {
                aacVersionResultMessage = L10n.format("Could not create AAC version: %@", error.localizedDescription)
            }

            aacVersionResultPresented = true
        }
    }

    func continueFinderExport(plan: MediaExportPlan, nameOverrides: [UUID: String]) {
        isPreparingExport = true
        Task {
            defer { isPreparingExport = false }
            await exportToFinder(plan: plan, nameOverrides: nameOverrides)
        }
    }

    func exportToFinder(plan: MediaExportPlan, nameOverrides: [UUID: String]) async {
        #if os(iOS)
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #else
        guard let destinationURL = chooseExportDirectory() else { return }
        #endif
        let files = plan.resolvedFiles(nameOverrides: nameOverrides)
        let result = await libraryService.export(files: files, to: destinationURL)
        #if os(iOS)
        let exportedURLs = await Task.detached {
            let enumerator = FileManager.default.enumerator(
                at: destinationURL, includingPropertiesForKeys: [.isRegularFileKey]
            )
            return (enumerator?.allObjects as? [URL] ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }.value
        if exportedURLs.isEmpty == false {
            let session = SharedExportSession(directory: destinationURL, urls: exportedURLs)
            sharedExportSession = session
            phoneExportSheet = .share(session)
        } else {
            await Task.detached { try? FileManager.default.removeItem(at: destinationURL) }.value
        }
        #endif
        var messages: [String] = []

        if result.exportedCount > 0 {
            messages.append(L10n.format("Exported %d media files.", result.exportedCount))
        }
        messages.append(contentsOf: plan.preparationErrors)
        messages.append(contentsOf: result.errors)

        exportResultMessage = messages.isEmpty ? L10n.string("Export completed.") : messages.joined(separator: "\n")
        #if os(iOS)
        showsExportErrorsAfterSharing = !result.errors.isEmpty || !plan.preparationErrors.isEmpty
        exportResultPresented = phoneExportSheet == nil
        #else
        exportResultPresented = true
        #endif
    }

    func chooseExportDirectory() -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.string("Export")
        panel.message = L10n.string("Choose a folder to export media.")
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }

    @discardableResult
    func createPlaylist() -> Playlist {
        let playlist = Playlist(name: uniquePlaylistName())
        modelContext.insert(playlist)
        save()
        selection = .playlist(playlist.id)
        return playlist
    }

    func createPlaylist(with item: MediaItem) {
        let playlist = createPlaylist()
        add([item], to: playlist)
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        playlist.name = trimmed
        save()
    }

    func deletePlaylist(_ playlist: Playlist) {
        browsingState.removePlaylist(playlist.id)
        modelContext.delete(playlist)
        save()
    }

    func addToPlaylist(_ item: MediaItem, _ playlist: Playlist) {
        add([item], to: playlist)
    }

    func add(_ newItems: [MediaItem], to playlist: Playlist) {
        var existingIDs = Set(playlist.entries.compactMap { $0.item?.id })
        var nextIndex = (playlist.entries.map(\.sortIndex).max() ?? -1) + 1

        for item in newItems where existingIDs.contains(item.id) == false {
            let entry = PlaylistEntry(sortIndex: nextIndex, playlist: playlist, item: item)
            playlist.entries.append(entry)
            modelContext.insert(entry)
            existingIDs.insert(item.id)
            nextIndex += 1
        }
        normalizeSortIndexes(for: playlist)
        save()
    }

    func removeFromSelectedPlaylist(_ item: MediaItem) {
        guard let selectedPlaylist else { return }
        for entry in selectedPlaylist.entries where entry.item?.id == item.id {
            modelContext.delete(entry)
        }
        normalizeSortIndexes(for: selectedPlaylist)
        save()
    }

    func moveInSelectedPlaylist(_ item: MediaItem, by offset: Int) {
        guard let selectedPlaylist else { return }
        selectedPlaylist.moveItem(item, by: offset)
        save()
    }

    func normalizeSortIndexes(for playlist: Playlist) {
        for (index, entry) in playlist.orderedEntries.enumerated() {
            entry.sortIndex = index
        }
    }

    func uniquePlaylistName() -> String {
        let baseName = L10n.string("New Playlist")
        let existingNames = Set(playlists.map(\.name))
        guard existingNames.contains(baseName) else { return baseName }

        var index = 2
        while existingNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    func save() {
        do {
            try modelContext.save()
        } catch {
            player.errorMessage = L10n.format("Could not save playlist: %@", error.localizedDescription)
        }
    }
}

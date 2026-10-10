import AVFoundation
import Foundation

struct MediaExportPlan: Identifiable {
    let id = UUID()
    let files: [MediaExportFileDraft]
    let preparationErrors: [String]
    /// Determined once because the name entry sheet reads it while the user types.
    let missingTitleFiles: [MediaExportFileDraft]

    init(files: [MediaExportFileDraft], preparationErrors: [String]) {
        self.files = files
        self.preparationErrors = preparationErrors
        missingTitleFiles = files.filter { $0.embeddedTitle == nil }
    }

    func resolvedFiles(nameOverrides: [UUID: String]) -> [MediaExportFile] {
        files.compactMap { draft in
            let title = draft.embeddedTitle ?? nameOverrides[draft.id]
            guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), title.isEmpty == false else {
                return nil
            }
            return MediaExportFile(
                id: draft.id,
                sourceURL: draft.sourceURL,
                albumName: draft.albumName,
                title: title,
                fileExtension: draft.fileExtension,
                originalFileName: draft.originalFileName
            )
        }
    }
}

struct MediaExportFileDraft: Identifiable {
    let id: UUID
    let sourceURL: URL
    let albumName: String
    let embeddedTitle: String?
    let fileExtension: String
    let originalFileName: String

    var displayName: String {
        originalFileName.isEmpty ? id.uuidString : originalFileName
    }
}

struct MediaExportFile: Identifiable, Sendable {
    let id: UUID
    let sourceURL: URL
    let albumName: String
    let title: String
    let fileExtension: String
    let originalFileName: String
}

struct MediaExportResult {
    let exportedCount: Int
    let errors: [String]
}

enum MediaExportNaming {
    nonisolated static let unnamedAlbumName = L10n.string("Untitled Album")

    nonisolated static func sanitizedPathComponent(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let invalidScalars = CharacterSet(charactersIn: "/:\0")
            .union(.newlines)
            .union(.controlCharacters)

        let sanitizedScalars = source.unicodeScalars.map { scalar in
            invalidScalars.contains(scalar) ? " " : String(scalar)
        }
        let sanitized = sanitizedScalars
            .joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard sanitized.isEmpty == false, sanitized != ".", sanitized != ".." else {
            return fallback
        }
        return sanitized
    }

    nonisolated static func timestampName(date: Date = Date(), index: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = formatter.string(from: date)

        guard let index else { return base }
        return "\(base)_\(String(format: "%03d", index))"
    }
}

extension LibraryService {
    /// Bounds the files opened at once while reading titles for a large selection.
    nonisolated static let exportPlanConcurrency = 4

    /// Reads export names in workers; the result keeps the order of `items`.
    func makeExportPlan(
        for items: [MediaItem], progress: ExportPlanPreparation? = nil
    ) async throws -> MediaExportPlan {
        let references = items.map(fileReference(for:))
        let throttle = ProgressReportThrottle()
        let entries = try await exportPlanEntries(for: references) { [weak progress] completedCount in
            guard let progress, throttle.shouldReport(Double(completedCount) / Double(references.count)) else {
                return
            }
            Task { @MainActor in progress.recordCompletedCount(completedCount) }
        }
        progress?.recordCompletedCount(entries.count)
        let drafts = zip(items, entries).map { item, entry in
            MediaExportFileDraft(
                id: item.id,
                sourceURL: entry.url,
                albumName: Self.normalizedExportAlbum(entry.album ?? item.album),
                embeddedTitle: entry.title,
                fileExtension: entry.url.pathExtension,
                originalFileName: item.fileName
            )
        }
        return MediaExportPlan(files: drafts, preparationErrors: [])
    }

    private nonisolated func exportPlanEntries(
        for references: [MediaFileReference], reportCompletedCount: @escaping @Sendable (Int) -> Void
    ) async throws -> [ExportPlanEntry] {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) { [self] in
            try await withThrowingTaskGroup(of: (Int, ExportPlanEntry).self) { group in
                var entries = [ExportPlanEntry?](repeating: nil, count: references.count)
                var nextIndex = 0
                var completedCount = 0
                func addNext() {
                    guard nextIndex < references.count, Task.isCancelled == false else { return }
                    let index = nextIndex
                    let reference = references[index]
                    nextIndex += 1
                    group.addTask { (index, try await self.exportPlanEntry(for: reference)) }
                }
                for _ in 0..<Self.exportPlanConcurrency { addNext() }
                while let (index, entry) = try await group.next() {
                    entries[index] = entry
                    completedCount += 1
                    reportCompletedCount(completedCount)
                    addNext()
                }
                try Task.checkCancellation()
                return entries.compactMap(\.self)
            }
        }
        return try await withTaskCancellationHandler {
            let entries = try await task.value
            try Task.checkCancellation()
            return entries
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated func exportPlanEntry(for reference: MediaFileReference) async throws -> ExportPlanEntry {
        try Task.checkCancellation()
        let url = try await FileSystemWorkQueue.runCancellable(
            qos: .userInitiated, limiter: exportPlanLimiter
        ) { [self] in
            resolvedURL(for: reference)
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        let metadata = try await Self.exportMetadata(for: url)
        try Task.checkCancellation()
        return ExportPlanEntry(url: url, title: metadata.title, album: metadata.album)
    }

    func export(files: [MediaExportFile], to destinationURL: URL) async -> MediaExportResult {
        guard files.isEmpty == false else {
            return MediaExportResult(exportedCount: 0, errors: [L10n.string("No media selected for export.")])
        }

        isExporting = true
        exportProgress = 0
        exportCompletedFileCount = 0
        exportTotalFileCount = files.count
        currentExportFileName = nil
        lastExportErrors = []

        var errors: [String] = []
        var exportedCount = 0
        var usedDestinationKeys = Set<String>()
        let didAccessDestination = destinationURL.startAccessingSecurityScopedResource()

        defer {
            if didAccessDestination {
                destinationURL.stopAccessingSecurityScopedResource()
            }
            lastExportErrors = errors
            isExporting = false
            exportProgress = 1
            exportCompletedFileCount = exportTotalFileCount
            currentExportFileName = nil
        }

        for (index, file) in files.enumerated() {
            currentExportFileName = file.originalFileName
            exportProgress = Double(index) / Double(files.count)
            await Task.yield()

            do {
                try await copyExportFile(file, to: destinationURL, usedDestinationKeys: &usedDestinationKeys)
                exportedCount += 1
            } catch {
                errors.append("\(file.originalFileName): \(error.localizedDescription)")
            }

            exportCompletedFileCount = index + 1
            exportProgress = Double(index + 1) / Double(files.count)
        }

        return MediaExportResult(exportedCount: exportedCount, errors: errors)
    }

    /// Unreadable metadata falls back to library values, but cancellation is rethrown so a cancelled plan
    /// does not keep reading the remaining sources.
    nonisolated static func exportMetadata(for url: URL) async throws -> (title: String?, album: String?) {
        do {
            if let info = try await ExtendedAudioSource.probeInfo(for: url) {
                return (info.title, info.album)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        var metadataItems: [AVMetadataItem] = []

        if let commonMetadata = try? await asset.load(.metadata) {
            metadataItems.append(contentsOf: commonMetadata)
        }
        try Task.checkCancellation()

        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                try Task.checkCancellation()
                if let formatMetadata = try? await asset.loadMetadata(for: format) {
                    metadataItems.append(contentsOf: formatMetadata)
                }
            }
        }
        try Task.checkCancellation()

        var title = await metadataItems.exportStringValue(for: .commonIdentifierTitle)
        if title == nil {
            title = await metadataItems.exportFirstString(whereKeyContains: ["tit2", "title", "©nam"])
        }
        try Task.checkCancellation()
        if title == nil {
            title = try await mp4NameTitleIfNeeded(for: url)
        }

        var album = await metadataItems.exportStringValue(for: .commonIdentifierAlbumName)
        if album == nil {
            album = await metadataItems.exportFirstString(whereKeyContains: ["talb", "album", "©alb"])
        }
        try Task.checkCancellation()

        return (title?.nilIfBlank, album?.nilIfBlank)
    }

    private nonisolated static func mp4NameTitleIfNeeded(for url: URL) async throws -> String? {
        guard ["mp4", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try MP4TitleReader.title(in: url)
        }
        return try await withTaskCancellationHandler {
            let title = try? await task.value
            try Task.checkCancellation()
            return title
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated func copyExportFile(
        _ file: MediaExportFile,
        to rootURL: URL,
        usedDestinationKeys: inout Set<String>
    ) async throws {
        let albumName = MediaExportNaming.sanitizedPathComponent(
            file.albumName,
            fallback: MediaExportNaming.unnamedAlbumName
        )
        let fileStem = MediaExportNaming.sanitizedPathComponent(file.title, fallback: MediaExportNaming.timestampName())
        let albumDirectory = rootURL.appendingPathComponent(albumName, isDirectory: true)
        let destinationURL = uniqueDestinationURL(
            in: albumDirectory,
            fileStem: fileStem,
            fileExtension: file.fileExtension,
            usedDestinationKeys: &usedDestinationKeys
        )

        let didAccessSource = file.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSource { file.sourceURL.stopAccessingSecurityScopedResource() }
        }

        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: albumDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file.sourceURL, to: destinationURL)
        }.value
    }

    private nonisolated func uniqueDestinationURL(
        in directory: URL,
        fileStem: String,
        fileExtension: String,
        usedDestinationKeys: inout Set<String>
    ) -> URL {
        var suffix = 1

        while true {
            let candidateStem = suffix == 1 ? fileStem : "\(fileStem)_\(suffix)"
            let candidateURL = fileExtension.isEmpty
                ? directory.appendingPathComponent(candidateStem)
                : directory.appendingPathComponent(candidateStem).appendingPathExtension(fileExtension)
            let key = candidateURL.path

            if usedDestinationKeys.contains(key) == false
                && FileManager.default.fileExists(atPath: candidateURL.path) == false {
                usedDestinationKeys.insert(key)
                return candidateURL
            }

            suffix += 1
        }
    }

    private static func normalizedExportAlbum(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != "Unknown Album" else {
            return MediaExportNaming.unnamedAlbumName
        }
        return trimmed
    }
}

private nonisolated struct ExportPlanEntry: Sendable {
    let url: URL
    let title: String?
    let album: String?
}

private nonisolated extension Array where Element == AVMetadataItem {
    func exportStringValue(for identifier: AVMetadataIdentifier) async -> String? {
        for item in AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier) {
            if let string = try? await item.load(.stringValue), let value = string.nilIfBlank {
                return value
            }
        }
        return nil
    }

    func exportFirstString(whereKeyContains needles: [String]) async -> String? {
        for item in self {
            let haystacks = [
                item.identifier?.rawValue,
                item.commonKey?.rawValue,
                item.key as? String
            ].compactMap { $0?.lowercased() }

            if haystacks.contains(where: { value in needles.contains(where: { value.contains($0.lowercased()) }) }) {
                if let string = try? await item.load(.stringValue), let value = string.nilIfBlank {
                    return value
                }
            }
        }
        return nil
    }
}

private nonisolated extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

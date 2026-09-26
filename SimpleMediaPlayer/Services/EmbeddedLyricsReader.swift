import AVFoundation
import Foundation

nonisolated struct EmbeddedLyricsReader: Sendable {
    private let readMP4: @Sendable (URL) throws -> String?
    private let readAsset: @Sendable (URL) async throws -> String?
    private static let keyNeedles = ["lyrics", "ult", "uslt", "sylt", "©lyr", "lyr"]

    init(
        readMP4: @escaping @Sendable (URL) throws -> String? = { try MP4MetadataReader.read(from: $0)?.lyrics },
        readAsset: @escaping @Sendable (URL) async throws -> String? = { try await Self.assetLyrics(from: $0) }
    ) {
        self.readMP4 = readMP4
        self.readAsset = readAsset
    }

    func read(from url: URL) async throws -> String? {
        try Task.checkCancellation()
        let task = Task<String?, any Error>.detached(priority: .utility) {
            try Task.checkCancellation()
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            if MP4MetadataWriter.canWriteMetadata(to: url) {
                let lyrics: String?
                do {
                    lyrics = try readMP4(url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lyrics = nil
                }
                try Task.checkCancellation()
                if let lyrics = Self.nonempty(lyrics) { return lyrics }
            }

            let hasCustomReader = AdditionalAudioMetadata.canWrite(to: url)
            if hasCustomReader {
                let lyrics = try AdditionalAudioMetadata.read(from: url).lyrics
                try Task.checkCancellation()
                if let lyrics = Self.nonempty(lyrics) { return lyrics }
            }

            try Task.checkCancellation()
            do {
                let lyrics = try await readAsset(url)
                try Task.checkCancellation()
                return Self.nonempty(lyrics)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || hasCustomReader == false { throw error }
                return nil
            }
        }
        return try await withTaskCancellationHandler {
            let lyrics = try await task.value
            try Task.checkCancellation()
            return lyrics
        } onCancel: {
            task.cancel()
        }
    }

    private static func assetLyrics(from url: URL) async throws -> String? {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await assetLyrics(in: asset)
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func assetLyrics(in asset: AVURLAsset) async throws -> String? {
        var firstError: (any Error)?

        do {
            if let lyrics = try await firstLyrics(in: asset.load(.metadata)) { return lyrics }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            firstError = error
        }
        try Task.checkCancellation()

        let formats: [AVMetadataFormat]
        do {
            formats = try await asset.load(.availableMetadataFormats)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        for format in formats {
            try Task.checkCancellation()
            do {
                if let lyrics = try await firstLyrics(in: asset.loadMetadata(for: format)) { return lyrics }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if firstError == nil { firstError = error }
            }
        }
        try Task.checkCancellation()
        if let firstError { throw firstError }
        return nil
    }

    private static func firstLyrics(in metadata: [AVMetadataItem]) async throws -> String? {
        var firstError: (any Error)?
        for item in metadata {
            try Task.checkCancellation()
            let keys = [item.identifier?.rawValue, item.commonKey?.rawValue, item.key as? String]
                .compactMap { $0?.lowercased() }
            guard keys.contains(where: { key in keyNeedles.contains { key.contains($0) } }) else { continue }
            do {
                let lyrics = try await item.load(.stringValue)
                try Task.checkCancellation()
                if let lyrics = nonempty(lyrics) { return lyrics }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return nil
    }

    private static func nonempty(_ lyrics: String?) -> String? {
        guard let lyrics, lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return lyrics
    }
}

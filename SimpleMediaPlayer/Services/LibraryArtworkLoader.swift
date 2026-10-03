import CoreGraphics
import Foundation
import ImageIO
import SwiftData

/// Reads and decodes artwork away from MainActor. Only decoded, size-specific images are cached.
actor LibraryArtworkLoader {
    static let shared = LibraryArtworkLoader()

    private struct Key: Hashable {
        let container: ObjectIdentifier
        let artworkID: UUID
        let pixelSize: Int
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastAccess: UInt64
    }

    private let byteLimit: Int
    private let read: @Sendable (UUID, ModelContainer) throws -> Data?
    private var entries: [Key: Entry] = [:]
    private var access: UInt64 = 0
    private(set) var cachedByteCount = 0
    var cachedImageCount: Int { entries.count }

    init(
        byteLimit: Int = 32 * 1_024 * 1_024,
        read: @escaping @Sendable (UUID, ModelContainer) throws -> Data? = LibraryArtworkLoader.readData
    ) {
        self.byteLimit = max(0, byteLimit)
        self.read = read
    }

    func data(for artworkID: UUID, in container: ModelContainer) throws -> Data? {
        try Task.checkCancellation()
        let data = try autoreleasepool { try read(artworkID, container) }
        try Task.checkCancellation()
        return data
    }

    @MainActor
    func image(for artworkID: UUID, in context: ModelContext, maxPixelSize: Int) async throws -> CGImage? {
        let pendingData = LibraryArtworkStorage.pendingData(for: artworkID, in: context)
        return try await image(
            for: artworkID, in: context.container, maxPixelSize: maxPixelSize, pendingData: pendingData
        )
    }

    func image(
        for artworkID: UUID,
        in container: ModelContainer,
        maxPixelSize: Int,
        pendingData: Data? = nil
    ) throws -> CGImage? {
        try Task.checkCancellation()
        let pixelSize = min(max(maxPixelSize, 1), 600)
        let key = Key(container: ObjectIdentifier(container), artworkID: artworkID, pixelSize: pixelSize)
        access &+= 1
        if var entry = entries[key] {
            entry.lastAccess = access
            entries[key] = entry
            return entry.image
        }

        let image: CGImage? = try autoreleasepool {
            guard let data = try pendingData ?? read(artworkID, container),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        try Task.checkCancellation()
        guard let image else { return nil }
        let cost = image.bytesPerRow * image.height
        if cost <= byteLimit {
            while cachedByteCount + cost > byteLimit,
                  let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                cachedByteCount -= oldest.value.cost
                entries[oldest.key] = nil
            }
            entries[key] = Entry(image: image, cost: cost, lastAccess: access)
            cachedByteCount += cost
        }
        return image
    }

    private nonisolated static func readData(_ artworkID: UUID, _ container: ModelContainer) throws -> Data? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<MediaArtwork>(predicate: #Predicate { $0.id == artworkID })
        descriptor.fetchLimit = 1
        guard let artwork = try context.fetch(descriptor).first else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return artwork.data
    }
}

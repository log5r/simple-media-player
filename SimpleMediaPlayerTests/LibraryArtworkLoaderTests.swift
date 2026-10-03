import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import SimpleMediaPlayer

@MainActor
struct LibraryArtworkLoaderTests {
    @Test func cachesOnlyRequestedSizesWithinByteLimit() async throws {
        let container = try makeContainer()
        let probe = ArtworkReadProbe(data: try makeImage())
        let loader = LibraryArtworkLoader(byteLimit: 64 * 1_024, read: probe.read)
        let firstID = UUID()

        let first = try #require(await loader.image(for: firstID, in: container, maxPixelSize: 32))
        #expect(first.width == 32)
        #expect(first.height == 32)
        _ = try await loader.image(for: firstID, in: container, maxPixelSize: 32)
        #expect(probe.readCount == 1)
        #expect(probe.wasMainThread == false)

        for _ in 0..<100 {
            _ = try await loader.image(for: UUID(), in: container, maxPixelSize: 32)
            #expect(await loader.cachedByteCount <= 64 * 1_024)
        }
        #expect(await loader.cachedImageCount < 100)
        let readsBeforeEviction = probe.readCount
        _ = try await loader.image(for: firstID, in: container, maxPixelSize: 32)
        #expect(probe.readCount == readsBeforeEviction + 1)
        _ = try await loader.image(for: firstID, in: container, maxPixelSize: 64)
        #expect(probe.readCount == readsBeforeEviction + 2)
    }

    @Test func oversizedImagesAreReturnedWithoutExceedingCacheBudget() async throws {
        let container = try makeContainer()
        let probe = ArtworkReadProbe(data: try makeImage())
        let loader = LibraryArtworkLoader(byteLimit: 1, read: probe.read)
        let image = try await loader.image(for: UUID(), in: container, maxPixelSize: 600)
        #expect(image != nil)
        #expect(await loader.cachedByteCount == 0)
        #expect(await loader.cachedImageCount == 0)
    }

    @Test func cancellationBeforeReadingDoesNotPopulateCache() async throws {
        let container = try makeContainer()
        let probe = ArtworkReadProbe(data: try makeImage())
        let loader = LibraryArtworkLoader(read: probe.read)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.image(for: UUID(), in: container, maxPixelSize: 32)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.readCount == 0)
        #expect(await loader.cachedByteCount == 0)
    }

    @Test func cancellationDuringReadDoesNotPublishOrCacheImage() async throws {
        let container = try makeContainer()
        let probe = ArtworkReadProbe(data: try makeImage(), blocks: true)
        let loader = LibraryArtworkLoader(read: probe.read)
        let task = Task { try await loader.image(for: UUID(), in: container, maxPixelSize: 32) }
        defer { probe.release() }
        try await waitUntilReading(probe)
        // Reaching this point on MainActor while the reader is blocked proves the actor can still run.
        #expect(Thread.isMainThread)
        task.cancel()
        probe.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await loader.cachedByteCount == 0)
    }

    @Test(arguments: [false, true])
    func delayedReadCannotApplyAfterArtworkReplacementOrItemDeletion(deleteItem: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(
            title: "Track", duration: 1, isVideo: false, bookmarkData: Data(),
            artworkData: Data([1]), fileName: "track.mp3"
        )
        context.insert(item)
        try context.save()
        let probe = ArtworkReadProbe(data: Data([1]), blocks: true)
        let service = LibraryService(artworkLoader: LibraryArtworkLoader(read: probe.read))
        let task = Task { try await service.libraryArtwork(for: item) }
        defer { probe.release() }
        try await waitUntilReading(probe)

        if deleteItem {
            context.delete(item)
        } else {
            item.artworkData = Data([2])
        }
        try context.save()
        probe.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func workerReadSeesReplacementAndExplicitRemovalAfterSave() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(
            title: "Track", duration: 1, isVideo: false, bookmarkData: Data(),
            artworkData: Data([1]), fileName: "track.mp3"
        )
        context.insert(item)
        try context.save()
        let service = LibraryService()
        #expect(try await service.libraryArtwork(for: item) == Data([1]))
        item.artworkData = Data([2])
        try context.save()
        #expect(try await service.libraryArtwork(for: item) == Data([2]))
        item.artworkData = nil
        try context.save()
        #expect(try await service.libraryArtwork(for: item) == nil)
    }

    @Test func unsavedArtworkIsReadFromPendingInsertsWithoutWorkerIO() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(
            title: "Track", duration: 1, isVideo: false, bookmarkData: Data(),
            artworkData: Data([1]), fileName: "track.mp3"
        )
        let probe = ArtworkReadProbe(data: Data([0xFF]))
        let service = LibraryService(artworkLoader: LibraryArtworkLoader(read: probe.read))
        context.insert(item)
        #expect(try await service.libraryArtwork(for: item) == Data([1]))
        #expect(probe.readCount == 0)
        try context.save()

        item.artworkData = Data([2])
        #expect(try await service.libraryArtwork(for: item) == Data([2]))
        #expect(probe.readCount == 0)
        item.artworkData = nil
        #expect(try await service.libraryArtwork(for: item) == nil)
        #expect(probe.readCount == 0)
    }

    @Test func pendingImagesDecodeBeforeBatchSaveAndReuseTheCacheAfterSave() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let data = try makeImage()
        let item = MediaItem(
            title: "Pending", duration: 1, isVideo: false, bookmarkData: Data(),
            artworkData: data, fileName: "pending.mp3"
        )
        context.insert(item)
        let probe = ArtworkReadProbe(data: data)
        let loader = LibraryArtworkLoader(read: probe.read)
        let artworkID = try #require(item.artworkID)

        let image = try #require(await loader.image(for: artworkID, in: context, maxPixelSize: 32))
        #expect(image.width == 32)
        #expect(probe.readCount == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<MediaArtwork>()) == 0)

        item.artworkData = data
        let replacementID = try #require(item.artworkID)
        #expect(replacementID != artworkID)
        #expect(try await loader.image(for: replacementID, in: context, maxPixelSize: 32) != nil)
        #expect(probe.readCount == 0)

        try context.save()
        #expect(try await loader.image(for: replacementID, in: context, maxPixelSize: 32) != nil)
        #expect(probe.readCount == 0)
        #expect(try await loader.image(for: replacementID, in: context, maxPixelSize: 64) != nil)
        #expect(probe.readCount == 1)
        #expect(probe.wasMainThread == false)
    }

    private func waitUntilReading(_ probe: ArtworkReadProbe) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while probe.readCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(probe.readCount == 1)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
    }

    private func makeImage() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let image = try #require(context.makeImage())
        let data = try #require(CFDataCreateMutable(nil, 0))
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

nonisolated private final class ArtworkReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let data: Data
    private let blocks: Bool
    private var count = 0
    private var mainThread = false

    init(data: Data, blocks: Bool = false) {
        self.data = data
        self.blocks = blocks
    }

    var readCount: Int { lock.withLock { count } }
    var wasMainThread: Bool { lock.withLock { mainThread } }

    func read(_ artworkID: UUID, _ container: ModelContainer) throws -> Data? {
        lock.withLock {
            count += 1
            mainThread = mainThread || Thread.isMainThread
        }
        if blocks {
            guard gate.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        }
        return data
    }

    func release() { gate.signal() }
}

import Foundation
import SwiftData
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryArtworkStorageTests {
    @Test func newArtworkIsStoredSeparatelyAndSurvivesReopening() throws {
        try withTemporaryArtworkStorage { directory in
            let bytes = Data(repeating: 0xA5, count: 256 * 1_024)
            let artworkID = try autoreleasepool {
                let container = try directory.makeContainer()
                let item = makeItem(artwork: bytes)
                container.mainContext.insert(item)
                try container.mainContext.save()
                #expect(item.legacyArtworkData == nil)
                return try #require(item.artworkID)
            }

            let container = try directory.makeContainer()
            let item = try #require(container.mainContext.fetch(FetchDescriptor<MediaItem>()).first)
            #expect(item.hasArtwork)
            #expect(item.artworkID == artworkID)
            #expect(item.legacyArtworkData == nil)
            let artwork = try #require(container.mainContext.fetch(FetchDescriptor<MediaArtwork>()).first)
            #expect(artwork.id == artworkID)
            #expect(artwork.data == bytes)
        }
    }

    @Test func replacingAndClearingArtworkRemovesPreviousEntities() throws {
        try withTemporaryArtworkStorage { directory in
            try autoreleasepool {
                let container = try directory.makeContainer()
                let context = container.mainContext
                let item = makeItem(artwork: Data([1, 2, 3]))
                context.insert(item)
                try context.save()
                let originalID = try #require(item.artworkID)

                item.artworkData = Data([1, 2, 3])
                try context.save()
                let replacementID = try #require(item.artworkID)
                #expect(replacementID != originalID)
                let replacements = try ModelContext(container).fetch(FetchDescriptor<MediaArtwork>())
                #expect(replacements.count == 1)
                #expect(replacements.first?.id == replacementID)

                item.artworkData = nil
                try context.save()
                #expect(item.hasArtwork == false)
                #expect(item.artworkID == nil)
                #expect(item.legacyArtworkData == nil)
                #expect(try ModelContext(container).fetchCount(FetchDescriptor<MediaArtwork>()) == 0)
            }

            let container = try directory.makeContainer()
            let savedItem = try #require(container.mainContext.fetch(FetchDescriptor<MediaItem>()).first)
            #expect(savedItem.hasArtwork == false)
            #expect(savedItem.artworkData == nil)
            #expect(savedItem.legacyArtworkData == nil)
        }
    }

    @Test func clearingLegacyArtworkDoesNotRestoreItDuringMigration() async throws {
        try await withTemporaryArtworkStorage { directory in
            let container = try directory.makeContainer()
            try autoreleasepool {
                let context = ModelContext(container)
                let item = makeItem()
                item.legacyArtworkData = Data([8, 9])
                context.insert(item)
                try context.save()
                item.artworkData = nil
                try context.save()
            }

            try await LibraryArtworkStorage.migrate(in: container)

            let context = ModelContext(container)
            let item = try #require(context.fetch(FetchDescriptor<MediaItem>()).first)
            #expect(item.artworkData == nil)
            #expect(item.hasArtwork == false)
            #expect(try context.fetchCount(FetchDescriptor<MediaArtwork>()) == 0)
        }
    }

    @Test func deletingItemCascadesOnlyItsOwnArtwork() throws {
        try withTemporaryArtworkStorage { directory in
            let container = try directory.makeContainer()
            let context = container.mainContext
            let first = makeItem(artwork: Data([1]))
            let second = makeItem(artwork: Data([2]))
            context.insert(first)
            context.insert(second)
            try context.save()
            let secondID = try #require(second.artworkID)

            context.delete(first)
            try context.save()

            let verification = ModelContext(container)
            #expect(try verification.fetchCount(FetchDescriptor<MediaItem>()) == 1)
            let artwork = try verification.fetch(FetchDescriptor<MediaArtwork>())
            #expect(artwork.count == 1)
            #expect(artwork.first?.id == secondID)
            #expect(artwork.first?.data == Data([2]))
        }
    }

    @Test func canceledMigrationLeavesLegacyBytesForTheNextLaunch() async throws {
        try await withTemporaryArtworkStorage { directory in
            let container = try directory.makeContainer()
            try autoreleasepool {
                let context = ModelContext(container)
                let item = makeItem()
                item.legacyArtworkData = Data([4, 5])
                context.insert(item)
                try context.save()
            }
            let migration = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                try await LibraryArtworkStorage.migrate(in: container)
            }
            do {
                try await migration.value
                Issue.record("Canceled migration should throw")
            } catch is CancellationError {
                let context = ModelContext(container)
                let item = try #require(context.fetch(FetchDescriptor<MediaItem>()).first)
                #expect(item.legacyArtworkData == Data([4, 5]))
                #expect(item.artworkID == nil)
                #expect(try context.fetchCount(FetchDescriptor<MediaArtwork>()) == 0)
            }

            try await LibraryArtworkStorage.migrate(in: container)

            let context = ModelContext(container)
            let item = try #require(context.fetch(FetchDescriptor<MediaItem>()).first)
            #expect(item.legacyArtworkData == nil)
            #expect(item.artworkData == Data([4, 5]))
            #expect(try context.fetchCount(FetchDescriptor<MediaArtwork>()) == 1)
        }
    }

    @Test func migrationResumesMixedLibraryAndPreservesPlaylists() async throws {
        try await withTemporaryArtworkStorage { directory in
            let container = try directory.makeContainer()
            let convertedID = try autoreleasepool {
                let context = ModelContext(container)
                let converted = makeItem(title: "Converted", artwork: Data([1]))
                let legacy = makeItem(title: "Legacy")
                legacy.legacyArtworkData = Data([2, 3])
                let empty = makeItem(title: "Empty legacy data")
                empty.legacyArtworkData = Data()
                let missing = makeItem(title: "No artwork")
                let playlist = Playlist(name: "Keep this playlist")
                context.insert(playlist)
                for (index, item) in [converted, legacy, empty, missing].enumerated() {
                    context.insert(item)
                    context.insert(PlaylistEntry(sortIndex: index, playlist: playlist, item: item))
                }
                try context.save()
                return try #require(converted.artworkID)
            }

            try await LibraryArtworkStorage.migrate(in: container)
            try await LibraryArtworkStorage.migrate(in: container)

            let context = ModelContext(container)
            let items = try context.fetch(FetchDescriptor<MediaItem>())
            #expect(items.count == 4)
            #expect(items.allSatisfy { $0.legacyArtworkData == nil })
            let converted = try #require(items.first { $0.title == "Converted" })
            #expect(converted.artworkID == convertedID)
            #expect(converted.artworkData == Data([1]))
            #expect(items.first { $0.title == "Legacy" }?.artworkData == Data([2, 3]))
            #expect(items.first { $0.title == "Empty legacy data" }?.artworkData == Data())
            #expect(items.first { $0.title == "No artwork" }?.hasArtwork == false)
            #expect(try context.fetchCount(FetchDescriptor<MediaArtwork>()) == 3)
            let playlist = try #require(context.fetch(FetchDescriptor<Playlist>()).first)
            #expect(playlist.name == "Keep this playlist")
            let entries = playlist.entries.sorted { $0.sortIndex < $1.sortIndex }
            #expect(entries.map { $0.item?.title } == ["Converted", "Legacy", "Empty legacy data", "No artwork"])
            #expect(entries.allSatisfy { $0.playlist?.id == playlist.id })
        }
    }

    private func makeItem(title: String = "Track", artwork: Data? = nil) -> MediaItem {
        MediaItem(
            title: title,
            duration: 1,
            isVideo: false,
            bookmarkData: Data(),
            artworkData: artwork,
            fileName: "track.mp3"
        )
    }
}

struct ArtworkStorageTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func makeContainer() throws -> ModelContainer {
        let schema = Schema([MediaItem.self, Playlist.self, PlaylistEntry.self])
        let configuration = ModelConfiguration(
            schema: schema,
            url: url.appendingPathComponent("library.store"),
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
func withTemporaryArtworkStorage(_ body: (ArtworkStorageTestDirectory) throws -> Void) throws {
    let directory = try ArtworkStorageTestDirectory()
    defer { directory.remove() }
    try autoreleasepool { try body(directory) }
}

@MainActor
func withTemporaryArtworkStorage(_ body: (ArtworkStorageTestDirectory) async throws -> Void) async throws {
    let directory = try ArtworkStorageTestDirectory()
    defer { directory.remove() }
    try await body(directory)
}

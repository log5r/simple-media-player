import Foundation

/// Records managed files whose library items are deleted before the files are removed in the background,
/// so a removal interrupted by termination runs again at the next launch.
nonisolated final class PendingFileRemovalJournal: @unchecked Sendable {
    enum Location: Sendable, Equatable {
        /// A file in the media directory of the library with this ID. The name is resolved against the
        /// directory at retry time, so the entry still applies after iOS moves the app's container.
        case managed(fileName: String, libraryID: String)
        /// An absolute path, as entries written before library IDs were recorded store it.
        case legacyPath(String)
    }

    struct Entry: Sendable, Equatable {
        let id: UUID
        let bookmarkData: Data
        let location: Location

        init(id: UUID, bookmarkData: Data, fileName: String, libraryID: String) {
            self.init(id: id, bookmarkData: bookmarkData, location: .managed(fileName: fileName, libraryID: libraryID))
        }

        init(id: UUID, bookmarkData: Data, location: Location) {
            self.id = id
            self.bookmarkData = bookmarkData
            self.location = location
        }
    }

    private static let key = "PendingMediaFileRemovals"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func add(_ entry: Entry) {
        var value: [String: Any] = ["bookmark": entry.bookmarkData]
        switch entry.location {
        case let .managed(fileName, libraryID):
            value["fileName"] = fileName
            value["library"] = libraryID
        case let .legacyPath(path):
            value["fallbackPath"] = path
        }
        lock.withLock {
            var stored = storedEntries()
            stored[entry.id.uuidString] = value
            defaults.set(stored, forKey: Self.key)
        }
    }

    func remove(id: UUID) {
        lock.withLock {
            var stored = storedEntries()
            guard stored.removeValue(forKey: id.uuidString) != nil else { return }
            if stored.isEmpty {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(stored, forKey: Self.key)
            }
        }
    }

    /// Entries are scoped by library so services with separate media directories do not remove each other's
    /// files. Entries of the earlier format are matched by the prefix of their absolute path instead.
    func entries(forLibrary libraryID: String, mediaDirectory: URL) -> [Entry] {
        let prefix = mediaDirectory.path.hasSuffix("/") ? mediaDirectory.path : mediaDirectory.path + "/"
        return lock.withLock {
            storedEntries().compactMap { key, value in
                guard let id = UUID(uuidString: key), let bookmarkData = value["bookmark"] as? Data else { return nil }
                if let fileName = value["fileName"] as? String, let library = value["library"] as? String {
                    guard library == libraryID else { return nil }
                    return Entry(id: id, bookmarkData: bookmarkData, fileName: fileName, libraryID: library)
                }
                guard let path = value["fallbackPath"] as? String, path.hasPrefix(prefix) else { return nil }
                return Entry(id: id, bookmarkData: bookmarkData, location: .legacyPath(path))
            }
        }
    }

    private func storedEntries() -> [String: [String: Any]] {
        defaults.dictionary(forKey: Self.key) as? [String: [String: Any]] ?? [:]
    }
}

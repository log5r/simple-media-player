import Foundation

/// Records managed files whose library items are deleted before the files are removed in the background,
/// so a removal interrupted by termination runs again at the next launch.
nonisolated final class PendingFileRemovalJournal: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let id: UUID
        let bookmarkData: Data
        let fallbackPath: String
    }

    private static let key = "PendingMediaFileRemovals"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func add(_ entry: Entry) {
        lock.withLock {
            var stored = storedEntries()
            stored[entry.id.uuidString] = ["bookmark": entry.bookmarkData, "fallbackPath": entry.fallbackPath]
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

    /// Entries are scoped by media directory so services with separate directories do not remove each other's files.
    func entries(in directory: URL) -> [Entry] {
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return lock.withLock {
            storedEntries().compactMap { key, value in
                guard let id = UUID(uuidString: key),
                      let bookmarkData = value["bookmark"] as? Data,
                      let fallbackPath = value["fallbackPath"] as? String,
                      fallbackPath.hasPrefix(prefix)
                else { return nil }
                return Entry(id: id, bookmarkData: bookmarkData, fallbackPath: fallbackPath)
            }
        }
    }

    private func storedEntries() -> [String: [String: Any]] {
        defaults.dictionary(forKey: Self.key) as? [String: [String: Any]] ?? [:]
    }
}

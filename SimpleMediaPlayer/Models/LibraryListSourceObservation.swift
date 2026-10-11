import Foundation
import Observation

@MainActor
@Observable
final class LibraryListObservationLifetime {
    var revision: UInt64 = 0
}

/// Only the generation counter is shared with Observation's synchronous callback.
/// Its lock never encloses model reads, snapshot work, or result publication.
nonisolated final class LibraryListGeneration: @unchecked Sendable {
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

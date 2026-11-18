import Darwin
import Foundation

/// Copies an imported file into the media directory with `copyfile(3)`. On the same APFS volume the file is
/// cloned, which is immediate and uses no space, like `FileManager.copyItem`. Otherwise the data is copied in
/// blocks, and the copy stops between blocks once `shouldStop` returns true.
nonisolated enum ManagedFileCopier {
    /// `allowsClone` is false only in tests, to exercise the block copy on a volume that supports clones.
    static func copy(
        from source: URL, to destination: URL, allowsClone: Bool = true,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws {
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passRetained(StopContext(shouldStop: shouldStop))
        defer { context.release() }
        let callback = unsafeBitCast(statusCallback, to: UnsafeRawPointer.self)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callback)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context.toOpaque())
        // `COPYFILE_CLONE` clones when it can and otherwise copies the data, stat, and extended attributes.
        let flags = allowsClone
            ? copyfile_flags_t(COPYFILE_CLONE)
            : copyfile_flags_t(COPYFILE_EXCL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(source.path, destination.path, state, flags) == 0 else {
            let code = errno
            if context.takeUnretainedValue().didStop { throw CancellationError() }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    nonisolated private final class StopContext {
        let shouldStop: @Sendable () -> Bool
        var didStop = false

        init(shouldStop: @escaping @Sendable () -> Bool) {
            self.shouldStop = shouldStop
        }
    }

    /// Called after each block of data; quitting leaves the partly written destination for the caller to remove.
    private static let statusCallback: copyfile_callback_t = { _, _, _, _, _, context in
        guard let context else { return COPYFILE_CONTINUE }
        let stopContext = Unmanaged<StopContext>.fromOpaque(context).takeUnretainedValue()
        guard stopContext.shouldStop() else { return COPYFILE_CONTINUE }
        stopContext.didStop = true
        return COPYFILE_QUIT
    }
}

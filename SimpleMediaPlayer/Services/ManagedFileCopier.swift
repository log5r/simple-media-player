import Darwin
import Foundation

/// Copies an imported file into the media directory with `copyfile(3)`. On the same APFS volume the file is
/// cloned, which is immediate and uses no space, like `FileManager.copyItem`. Otherwise the data is copied in
/// blocks, and the copy stops between blocks once `shouldStop` returns true.
nonisolated enum ManagedFileCopier {
    /// Why the status callback ended a copy.
    enum Interruption: Equatable {
        case stopped
        case failed(errno: Int32)
    }

    /// `allowsClone` is false only in tests, to exercise the block copy on a volume that supports clones.
    static func copy(
        from source: URL, to destination: URL, allowsClone: Bool = true,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws {
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passRetained(CallbackContext(shouldStop: shouldStop))
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
            switch context.takeUnretainedValue().interruption {
            case .stopped: throw CancellationError()
            // After a quit, copyfile reports ECANCELED, so the error the callback saw is thrown instead.
            case let .failed(callbackErrno): throw posixError(callbackErrno)
            case nil: throw posixError(code)
            }
        }
    }

    /// The extended attribute name copyfile reports while applying the source's quarantine to the copy.
    static let quarantineAttributeName = "com.apple.quarantine"

    /// Decides whether the copy goes on after a status callback; nil continues it.
    ///
    /// Errors are handled as copyfile handles them without a callback, which the earlier `copyItem` import
    /// relied on: a quarantine that cannot be applied is ignored, and any other error, in the data, the resource
    /// fork, or another extended attribute, fails the copy with the error it reported. Continuing instead would
    /// retry a failed data write without end when the disk is full, or register a copy missing an attribute.
    static func interruption(
        what: Int32, stage: Int32, attributeName: String?, errno: Int32, shouldStop: () -> Bool
    ) -> Interruption? {
        if shouldStop() { return .stopped }
        guard stage == COPYFILE_ERR else { return nil }
        if what == COPYFILE_COPY_XATTR, attributeName == quarantineAttributeName { return nil }
        return .failed(errno: errno == 0 ? EIO : errno)
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    nonisolated private final class CallbackContext {
        let shouldStop: @Sendable () -> Bool
        var interruption: Interruption?

        init(shouldStop: @escaping @Sendable () -> Bool) {
            self.shouldStop = shouldStop
        }
    }

    /// Called at each stage of the data and extended attribute copies, and after each block of data. Quitting
    /// leaves the partly written destination for the caller to remove.
    private static let statusCallback: copyfile_callback_t = { what, stage, state, _, _, context in
        guard let context else { return COPYFILE_QUIT }
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        let code = errno
        // copyfile names the attribute it is copying, or the quarantine it is applying, before an error callback.
        var attributeName: String?
        if stage == COPYFILE_ERR, what == COPYFILE_COPY_XATTR, let state {
            var name: UnsafeMutablePointer<CChar>?
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_XATTRNAME), &name) == 0, let name {
                attributeName = String(cString: name)
            }
        }
        guard let interruption = ManagedFileCopier.interruption(
            what: what, stage: stage, attributeName: attributeName, errno: code, shouldStop: callbackContext.shouldStop
        ) else { return COPYFILE_CONTINUE }
        callbackContext.interruption = interruption
        return COPYFILE_QUIT
    }
}

import Foundation

/// Decodes the readable content of an ID3v2 frame from its raw bytes, header included.
nonisolated enum ID3FrameContent {
    /// Returns the frame data without per-frame unsynchronisation and its header additions,
    /// or `nil` when the content is compressed, encrypted, uses reserved format flags,
    /// or its additions do not fit in the frame.
    static func readableContent(of frame: Data, version: UInt8) -> Data? {
        // ID3v2.2 frames have a 6-byte header without flags.
        guard version != 2 else { return frame.dropFirst(6) }
        guard frame.count >= 10 else { return nil }
        let formatFlags = frame[frame.startIndex + 9]
        guard let additionsLength = additionsLength(formatFlags: formatFlags, version: version) else { return nil }

        // ID3v2.4 §4.1.2 %0h00kmnp: with n, "all data from the end of this header to the end of this frame
        // has been unsynchronised". §4.1 places the additions after the frame header, so they are
        // unsynchronised too and must be decoded together with the frame data before being dropped.
        let body = frame.dropFirst(10)
        let decodedBody = version == 4 && formatFlags & 0x02 != 0 ? removingUnsynchronisation(from: body) : body
        guard additionsLength <= decodedBody.count else { return nil }
        return decodedBody.dropFirst(additionsLength)
    }

    /// Returns the number of bytes the format flags add after the frame header,
    /// or `nil` when the flags hide the content or set a bit the specification leaves undefined,
    /// since an unknown extension might change the layout of the frame data.
    private static func additionsLength(formatFlags: UInt8, version: UInt8) -> Int? {
        if version == 4 {
            // ID3v2.4 §4.1.2 %0h00kmnp: grouping (h) adds 1 byte, encryption (m) 1 byte,
            // and the data length indicator (p) a 4-byte synchsafe integer. Compression (k) and
            // encryption are not decoded. The bits outside %0h00kmnp are reserved.
            guard formatFlags & 0x0C == 0, formatFlags & ~0x4F == 0 else { return nil }
            return (formatFlags & 0x40 != 0 ? 1 : 0) + (formatFlags & 0x01 != 0 ? 4 : 0)
        }

        // ID3v2.3 §3.3.1 %ijk00000: compression (i) adds a 4-byte size, encryption (j) 1 byte,
        // and grouping (k) 1 byte. Compression and encryption are not decoded.
        // The bits outside %ijk00000 are reserved.
        guard formatFlags & 0xC0 == 0, formatFlags & ~0xE0 == 0 else { return nil }
        return formatFlags & 0x20 != 0 ? 1 : 0
    }

    /// ID3v2.4 §6.1: unsynchronisation inserts 0x00 after every 0xFF, so drop each 0x00 that follows 0xFF.
    private static func removingUnsynchronisation(from data: Data) -> Data {
        var decoded = Data()
        decoded.reserveCapacity(data.count)
        var previous: UInt8 = 0
        for byte in data {
            if previous != 0xFF || byte != 0x00 {
                decoded.append(byte)
            }
            previous = byte
        }
        return decoded
    }
}

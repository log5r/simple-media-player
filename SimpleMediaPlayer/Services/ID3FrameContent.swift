import Foundation

/// Decodes the readable content of an ID3v2 frame from its raw bytes, header included.
nonisolated enum ID3FrameContent {
    /// Returns the frame data without its header additions and per-frame unsynchronisation,
    /// or `nil` when the content is compressed, encrypted, or its additions do not fit in the frame.
    static func readableContent(of frame: Data, version: UInt8) -> Data? {
        // ID3v2.2 frames have a 6-byte header without flags.
        guard version != 2 else { return frame.dropFirst(6) }
        guard frame.count >= 10 else { return nil }
        let formatFlags = frame[frame.startIndex + 9]
        let body = frame.dropFirst(10)
        guard let additionsLength = additionsLength(formatFlags: formatFlags, version: version),
              additionsLength <= body.count
        else { return nil }

        let data = body.dropFirst(additionsLength)
        // ID3v2.4 §4.1.2 %0h00kmnp: n marks per-frame unsynchronisation, applied after the additions.
        return version == 4 && formatFlags & 0x02 != 0 ? removingUnsynchronisation(from: data) : data
    }

    /// Returns the number of bytes the format flags add after the frame header,
    /// or `nil` when the flags hide the content.
    private static func additionsLength(formatFlags: UInt8, version: UInt8) -> Int? {
        if version == 4 {
            // ID3v2.4 §4.1.2 %0h00kmnp: grouping (h) adds 1 byte, encryption (m) 1 byte,
            // and the data length indicator (p) a 4-byte synchsafe integer. Compression (k) and
            // encryption are not decoded.
            guard formatFlags & 0x0C == 0 else { return nil }
            return (formatFlags & 0x40 != 0 ? 1 : 0) + (formatFlags & 0x01 != 0 ? 4 : 0)
        }

        // ID3v2.3 §3.3.1 %ijk00000: compression (i) adds a 4-byte size, encryption (j) 1 byte,
        // and grouping (k) 1 byte. Compression and encryption are not decoded.
        guard formatFlags & 0xC0 == 0 else { return nil }
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

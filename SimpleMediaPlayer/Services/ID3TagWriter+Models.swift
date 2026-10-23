import Foundation

struct ID3TagHeader {
    let version: UInt8
    let flags: UInt8
    let contentEnd: Int
    let totalEnd: Int
}

struct ID3Tag {
    let version: UInt8
    let totalRange: Range<Int>
    let frames: [ID3Frame]

    nonisolated func preservedFrames(removing frameIDs: Set<String>, removeFrontArtwork: Bool) throws -> [Data] {
        // An unreadable frame might hold a value this save replaces; an unreadable APIC might be the front cover.
        let removesUnreadableFrame = frames.contains { frame in
            frame.content == nil && (frameIDs.contains(frame.id) || (removeFrontArtwork && frame.id == "APIC"))
        }
        guard removesUnreadableFrame == false else {
            throw MediaMetadataEditError.unsupportedID3Flags
        }

        return frames
            .filter { frame in
                frameIDs.contains(frame.id) == false && (removeFrontArtwork == false || frame.pictureType != 3)
            }
            .map(\.rawData)
    }
}

struct ID3Frame {
    let id: String
    let rawData: Data
    /// The frame data without header additions and unsynchronisation, or `nil` when it cannot be read.
    let content: Data?

    nonisolated init(id: String, rawData: Data, version: UInt8) {
        self.id = id
        self.rawData = rawData
        content = ID3FrameContent.readableContent(of: rawData, version: version)
    }

    /// Unreadable frames yield an empty payload so that readers skip them.
    nonisolated var payload: Data.SubSequence {
        content ?? Data()
    }

    nonisolated var pictureType: UInt8? {
        let data = payload
        guard data.count >= 5 else { return nil }
        if id == "PIC" { return data[data.startIndex + 4] }
        guard id == "APIC", let terminator = data[data.startIndex...].dropFirst().firstIndex(of: 0),
              terminator + 1 < data.endIndex else { return nil }
        return data[terminator + 1]
    }

    nonisolated var canonicalID: String {
        switch id {
        case "TT2":
            "TIT2"
        case "TP1":
            "TPE1"
        case "TAL":
            "TALB"
        case "TCO":
            "TCON"
        case "TYE":
            "TYER"
        case "TRK":
            "TRCK"
        case "COM":
            "COMM"
        case "TP2":
            "TPE2"
        case "TCM":
            "TCOM"
        case "TPA":
            "TPOS"
        case "TCP":
            "TCMP"
        default:
            id
        }
    }
}

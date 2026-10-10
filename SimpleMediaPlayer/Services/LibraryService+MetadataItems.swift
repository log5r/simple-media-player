import AVFoundation
import Foundation

/// Value readers shared by the import and the metadata editor; both run on `LibraryService`.
extension Array where Element == AVMetadataItem {
    func stringValue(for identifier: AVMetadataIdentifier) async -> String? {
        for item in AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier) {
            if let string = try? await item.load(.stringValue), string.isEmpty == false {
                return string
            }
        }
        return nil
    }

    func dataValue(for identifier: AVMetadataIdentifier) async -> Data? {
        for item in AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier) {
            if let data = try? await item.load(.dataValue) {
                return data
            }
        }
        return nil
    }

    func firstString(whereKeyContains needles: [String]) async -> String? {
        for item in self where item.matchesKeyNeedles(needles) {
            if let string = try? await item.load(.stringValue), string.isEmpty == false {
                return string
            }
        }
        return nil
    }

    func firstDisplayString(whereKeyContains needles: [String]) async -> String? {
        for item in self where item.matchesKeyNeedles(needles) {
            if let string = try? await item.load(.stringValue), string.isEmpty == false {
                return string
            }
            if let number = try? await item.load(.numberValue) {
                return number.stringValue
            }
            if let value = try? await item.load(.value),
               let string = Self.displayString(value),
               string.isEmpty == false {
                return string
            }
        }
        return nil
    }

    func firstBool(whereKeyContains needles: [String]) async -> Bool? {
        for item in self where item.matchesKeyNeedles(needles) {
            if let number = try? await item.load(.numberValue) {
                return number.boolValue
            }
            if let string = try? await item.load(.stringValue) {
                let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["1", "true", "yes"].contains(normalized) { return true }
                if ["0", "false", "no"].contains(normalized) { return false }
            }
            if let data = try? await item.load(.dataValue), let byte = data.last {
                return byte != 0
            }
        }
        return nil
    }

    static func displayString(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let number as NSNumber:
            return number.stringValue
        case let data as Data:
            return mp4NumberPairString(data)
        default:
            return nil
        }
    }

    static func mp4NumberPairString(_ data: Data) -> String? {
        let payload = data.count >= 8 ? Data(data.suffix(8)) : data
        guard payload.count >= 6 else { return nil }
        let start = payload.startIndex
        let current = UInt16(payload[start + 2]) << 8 | UInt16(payload[start + 3])
        let total = UInt16(payload[start + 4]) << 8 | UInt16(payload[start + 5])
        guard current > 0 else { return nil }
        return total > 0 ? "\(current)/\(total)" : "\(current)"
    }

    func embeddedValues(compilationKeyNeedles: [String]) async -> MediaMetadataEmbeddedValues {
        MediaMetadataEmbeddedValues(
            title: await stringValue(for: .commonIdentifierTitle),
            artist: await stringValue(for: .commonIdentifierArtist),
            album: await stringValue(for: .commonIdentifierAlbumName),
            genre: await firstString(whereKeyContains: ["genre", "gnre", "tco"]),
            year: await firstDisplayString(whereKeyContains: ["year", "date", "tdrc", "tyer", "tye", "©day"]),
            trackNumber: await firstDisplayString(
                whereKeyContains: ["track number", "tracknumber", "trck", "trk", "trkn"]
            ),
            comment: await firstDisplayString(whereKeyContains: ["comment", "comm", "©cmt"]),
            albumArtist: await firstDisplayString(
                whereKeyContains: ["album artist", "albumartist", "tpe2", "tp2", "aART"]
            ),
            composer: await firstDisplayString(whereKeyContains: ["composer", "tcom", "tcm", "©wrt"]),
            discNumber: await firstDisplayString(
                whereKeyContains: ["disc number", "discnumber", "disk", "tpos", "tpa"]
            ),
            isCompilation: await firstBool(whereKeyContains: compilationKeyNeedles)
        )
    }
}

extension AVMetadataItem {
    func matchesKeyNeedles(_ needles: [String]) -> Bool {
        let haystacks = [
            identifier?.rawValue,
            commonKey?.rawValue,
            key as? String
        ].compactMap { $0?.lowercased() }

        return haystacks.contains { value in
            needles.contains { value.contains($0.lowercased()) }
        }
    }
}

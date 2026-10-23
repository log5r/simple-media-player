import AVFoundation
import CoreMedia
import Foundation

extension MediaInfoInspector {
    private static func asyncMap<S: Sequence, T>(
        _ sequence: S, transform: (S.Element) async -> T
    ) async -> [T] {
        var values: [T] = []
        for element in sequence {
            values.append(await transform(element))
        }
        return values
    }

    static func trackSections(for asset: AVURLAsset) async throws -> [MediaInfoSection] {
        let tracks = try await asset.load(.tracks)

        return await asyncMap(tracks.enumerated()) { index, track in
            var rows: [MediaInfoRow] = [
                MediaInfoRow(id: "mediaType", label: L10n.string("Media Type"), value: track.mediaType.rawValue)
            ]

            if let naturalSize = try? await track.load(.naturalSize), naturalSize.width > 0 || naturalSize.height > 0 {
                rows.append(MediaInfoRow(
                    id: "naturalSize",
                    label: L10n.string("Dimensions"),
                    value: "\(Int(naturalSize.width.rounded())) x \(Int(naturalSize.height.rounded()))"
                ))
            }
            if let frameRate = try? await track.load(.nominalFrameRate), frameRate > 0 {
                rows.append(MediaInfoRow(
                    id: "frameRate",
                    label: L10n.string("Frame Rate"),
                    value: "\(MediaInfoTextFormatter.compactDecimal(Double(frameRate))) fps"
                ))
            }
            if let dataRate = try? await track.load(.estimatedDataRate), dataRate > 0 {
                rows.append(MediaInfoRow(
                    id: "dataRate",
                    label: L10n.string("Estimated Data Rate"),
                    value: "\(Int((dataRate / 1000).rounded())) kbps"
                ))
            }
            if let languageCode = try? await track.load(.languageCode), languageCode != "und" {
                rows.append(MediaInfoRow(id: "language", label: L10n.string("Language"), value: languageCode))
            }
            if let extendedLanguageTag = try? await track.load(.extendedLanguageTag) {
                rows.append(MediaInfoRow(
                    id: "extendedLanguage",
                    label: L10n.string("Extended Language"),
                    value: extendedLanguageTag
                ))
            }
            if let formatDescriptions = try? await track.load(.formatDescriptions) {
                rows.append(contentsOf: formatDescriptionRows(formatDescriptions))
            }

            let title = trackTitle(track, index: index)
            return MediaInfoSection(id: "track-\(index)", title: title, rows: rows)
        }
    }

    private static func trackTitle(_ track: AVAssetTrack, index: Int) -> String {
        L10n.format("Track %d - %@", index + 1, track.mediaType.rawValue)
    }

    static func formatDescriptionRows(_ descriptions: [CMFormatDescription]) -> [MediaInfoRow] {
        descriptions.enumerated().flatMap { index, description in
            var rows: [MediaInfoRow] = [
                MediaInfoRow(
                    id: "format-\(index)-mediaType",
                    label: L10n.format("Format %d Media Type", index + 1),
                    value: fourCharacterCode(CMFormatDescriptionGetMediaType(description))
                ),
                MediaInfoRow(
                    id: "format-\(index)-subtype",
                    label: L10n.format("Format %d Codec", index + 1),
                    value: fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
                )
            ]

            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            if dimensions.width > 0 || dimensions.height > 0 {
                rows.append(MediaInfoRow(
                    id: "format-\(index)-dimensions",
                    label: L10n.format("Format %d Dimensions", index + 1),
                    value: "\(dimensions.width) x \(dimensions.height)"
                ))
            }

            if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                rows.append(contentsOf: audioFormatRows(streamDescription, index: index))
            }

            if let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
               extensions.isEmpty == false,
               let formattedExtensions = displayValue(extensions) {
                rows.append(MediaInfoRow(
                    id: "format-\(index)-extensions",
                    label: L10n.format("Format %d Extensions", index + 1),
                    value: formattedExtensions
                ))
            }

            return rows
        }
    }

    private static func audioFormatRows(
        _ description: AudioStreamBasicDescription, index: Int
    ) -> [MediaInfoRow] {
        var rows = [
            MediaInfoRow(
                id: "format-\(index)-sampleRate",
                label: L10n.format("Format %d Sample Rate", index + 1),
                value: "\(MediaInfoTextFormatter.compactDecimal(description.mSampleRate)) Hz"
            ),
            MediaInfoRow(
                id: "format-\(index)-channels",
                label: L10n.format("Format %d Channels", index + 1),
                value: String(description.mChannelsPerFrame)
            )
        ]
        if description.mBitsPerChannel > 0 {
            rows.append(MediaInfoRow(
                id: "format-\(index)-bits",
                label: L10n.format("Format %d Bits per Channel", index + 1),
                value: String(description.mBitsPerChannel)
            ))
        }
        return rows
    }

    static func metadataLabel(for item: AVMetadataItem, fallback: String) -> String {
        if let commonKey = item.commonKey?.rawValue {
            return commonKey
        }
        if let identifier = item.identifier?.rawValue {
            return identifier
        }
        if let key = displayValue(item.key) {
            return key
        }
        return fallback
    }

    static func metadataValue(for item: AVMetadataItem) async -> String {
        if let string = try? await item.load(.stringValue), string.isEmpty == false {
            return string
        }
        if let number = try? await item.load(.numberValue) {
            return number.stringValue
        }
        if let date = try? await item.load(.dateValue) {
            return date.formatted(date: .numeric, time: .shortened)
        }
        if let data = try? await item.load(.dataValue) {
            if let text = String(data: data, encoding: .utf8),
               text.trimmingCharacters(in: .controlCharacters).isEmpty == false {
                return text
            }
            return L10n.format("Binary data (%@)", MediaInfoTextFormatter.fileSize(bytes: Int64(data.count)))
        }
        if let value = try? await item.load(.value) {
            return displayValue(value) ?? String(describing: value)
        }
        return L10n.string("No readable value")
    }

    static func metadataFormatTitle(_ format: AVMetadataFormat) -> String {
        switch format {
        case .id3Metadata:
            return L10n.string("ID3 Metadata")
        case .iTunesMetadata:
            return L10n.string("iTunes Metadata")
        case .quickTimeMetadata:
            return L10n.string("QuickTime Metadata")
        case .quickTimeUserData:
            return L10n.string("QuickTime User Data")
        case .isoUserData:
            return L10n.string("ISO User Data")
        default:
            return format.rawValue
        }
    }

    static func appendDetail(_ label: String, _ value: String?, to details: inout [String]) {
        guard let value, value.isEmpty == false else { return }
        details.append("\(label): \(value)")
    }

    static func displayValue(_ value: Any?) -> String? {
        guard let value else { return nil }

        switch value {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let number as NSNumber:
            return number.stringValue
        case let date as Date:
            return date.formatted(date: .numeric, time: .shortened)
        case let data as Data:
            return L10n.format("Binary data (%@)", MediaInfoTextFormatter.fileSize(bytes: Int64(data.count)))
        case let array as [Any]:
            return array.compactMap(displayValue).joined(separator: ", ")
        case let dictionary as [String: Any]:
            return displayDictionary(dictionary)
        case let dictionary as NSDictionary:
            let values = Dictionary(uniqueKeysWithValues: dictionary.allKeys.map { key in
                (String(describing: key), dictionary[key])
            })
            return displayDictionary(values)
        default:
            return String(describing: value)
        }
    }

    private static func displayDictionary(_ dictionary: [String: Any?]) -> String {
        dictionary.keys.sorted().compactMap { key in
            guard let value = displayValue(dictionary[key] ?? nil) else { return nil }
            return "\(key): \(value)"
        }.joined(separator: "\n")
    }

    static func fourCharacterCode(_ code: FourCharCode) -> String {
        let scalars = [
            UnicodeScalar((code >> 24) & 0xFF),
            UnicodeScalar((code >> 16) & 0xFF),
            UnicodeScalar((code >> 8) & 0xFF),
            UnicodeScalar(code & 0xFF)
        ]

        let string = scalars.compactMap { scalar -> Character? in
            guard let scalar, scalar.isASCII, scalar.value >= 32 else { return nil }
            return Character(scalar)
        }

        if string.count == 4 {
            return String(string)
        }
        return "0x\(String(code, radix: 16, uppercase: true))"
    }

    static func yesNo(_ value: Bool) -> String {
        value ? L10n.string("Yes") : L10n.string("No")
    }
}

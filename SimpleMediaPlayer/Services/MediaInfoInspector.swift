import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

private nonisolated struct FileAttributes: Sendable {
    let byteCount: Int?
    let contentType: UTType?
    let creationDate: Date?
    let contentModificationDate: Date?

    init(url: URL) {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .totalFileSizeKey,
            .contentTypeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        byteCount = values?.totalFileSize ?? values?.fileSize
        contentType = values?.contentType
        creationDate = values?.creationDate
        contentModificationDate = values?.contentModificationDate
    }
}

enum MediaInfoInspector {
    static func loadDetails(for item: MediaInfoItemSnapshot, url: URL) async -> MediaInfoDetails {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let attributes = await Task.detached(priority: .userInitiated) {
            FileAttributes(url: url)
        }.value
        let fileRows = fileRows(for: item, url: url, attributes: attributes)
        if let info = try? await ExtendedAudioSource.probeInfo(for: url) {
            var rows = [MediaInfoRow(id: "codec", label: L10n.string("Codec"), value: info.codec)]
            if let sampleRate = info.sampleRate {
                rows.append(MediaInfoRow(
                    id: "sampleRate", label: L10n.string("Sample Rate"),
                    value: "\(MediaInfoTextFormatter.compactDecimal(sampleRate)) Hz"
                ))
            }
            if let bitrate = info.bitrateKbps {
                rows.append(MediaInfoRow(
                    id: "bitrate", label: L10n.string("Bitrate"), value: "\(bitrate) kbps"
                ))
            }
            return MediaInfoDetails(
                fileRows: fileRows,
                summaryRows: summaryRows(for: item),
                sections: [MediaInfoSection(title: L10n.string("Audio"), rows: rows)],
                errorMessage: nil
            )
        }
        let asset = AVURLAsset(url: url)

        do {
            async let summaryRows = assetSummaryRows(for: item, asset: asset)
            async let metadataSections = metadataSections(for: asset)
            async let trackSections = trackSections(for: asset)

            return MediaInfoDetails(
                fileRows: fileRows,
                summaryRows: await summaryRows,
                sections: try await metadataSections + trackSections,
                errorMessage: nil
            )
        } catch {
            return MediaInfoDetails(
                fileRows: fileRows,
                summaryRows: summaryRows(for: item),
                sections: [],
                errorMessage: L10n.format("Could not read media info: %@", error.localizedDescription)
            )
        }
    }

    private static func fileRows(
        for item: MediaInfoItemSnapshot, url: URL, attributes: FileAttributes
    ) -> [MediaInfoRow] {
        let byteCount = attributes.byteCount

        var rows = [
            MediaInfoRow(id: "fileName", label: L10n.string("File"), value: item.fileName),
            MediaInfoRow(id: "filePath", label: L10n.string("File Path"), value: url.path)
        ]

        if let byteCount, byteCount >= 0 {
            rows.append(MediaInfoRow(
                id: "fileSize",
                label: L10n.string("File Size"),
                value: "\(MediaInfoTextFormatter.fileSize(bytes: Int64(byteCount))) (\(byteCount) bytes)"
            ))
        }
        if let type = attributes.contentType {
            rows.append(MediaInfoRow(id: "contentType", label: L10n.string("Content Type"), value: type.identifier))
        }
        if let creationDate = attributes.creationDate {
            rows.append(MediaInfoRow(
                id: "created",
                label: L10n.string("Created"),
                value: creationDate.formatted(date: .numeric, time: .shortened)
            ))
        }
        if let modifiedDate = attributes.contentModificationDate {
            rows.append(MediaInfoRow(
                id: "modified",
                label: L10n.string("Modified"),
                value: modifiedDate.formatted(date: .numeric, time: .shortened)
            ))
        }

        return rows
    }

    private static func summaryRows(for item: MediaInfoItemSnapshot) -> [MediaInfoRow] {
        var rows = [
            MediaInfoRow(id: "title", label: L10n.string("Title"), value: item.title),
            MediaInfoRow(id: "artist", label: L10n.string("Artist"), value: item.displayArtist),
            MediaInfoRow(id: "album", label: L10n.string("Album"), value: item.displayAlbum),
            MediaInfoRow(id: "genre", label: L10n.string("Genre"), value: item.displayGenre),
            MediaInfoRow(id: "duration", label: L10n.string("Time"), value: item.duration.mediaTime),
            MediaInfoRow(
                id: "kind",
                label: L10n.string("Kind"),
                value: item.isVideo ? L10n.string("Video") : L10n.string("Audio")
            ),
            MediaInfoRow(
                id: "added",
                label: L10n.string("Date Added"),
                value: item.addedAt.formatted(date: .numeric, time: .shortened)
            )
        ]
        appendOptionalRow(id: "year", label: L10n.string("Year"), value: item.year, to: &rows)
        appendOptionalRow(id: "trackNumber", label: L10n.string("Track"), value: item.trackNumber, to: &rows)
        appendOptionalRow(id: "albumArtist", label: L10n.string("Album Artist"), value: item.albumArtist, to: &rows)
        appendOptionalRow(id: "composer", label: L10n.string("Composer"), value: item.composer, to: &rows)
        appendOptionalRow(id: "discNumber", label: L10n.string("Disc Number"), value: item.discNumber, to: &rows)
        if item.isCompilation {
            rows.append(MediaInfoRow(id: "compilation", label: L10n.string("Compilation"), value: yesNo(true)))
        }
        appendOptionalRow(id: "comment", label: L10n.string("Comment"), value: item.comment, to: &rows)
        return rows
    }

    private static func appendOptionalRow(id: String, label: String, value: String?, to rows: inout [MediaInfoRow]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else { return }
        rows.append(MediaInfoRow(id: id, label: label, value: value))
    }

    private static func assetSummaryRows(for item: MediaInfoItemSnapshot, asset: AVURLAsset) async -> [MediaInfoRow] {
        var rows = summaryRows(for: item)

        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 {
            rows.append(MediaInfoRow(
                id: "assetDuration",
                label: L10n.string("Asset Duration"),
                value: duration.mediaTime
            ))
        }
        if let isPlayable = try? await asset.load(.isPlayable) {
            rows.append(MediaInfoRow(id: "isPlayable", label: L10n.string("Playable"), value: yesNo(isPlayable)))
        }
        if let isReadable = try? await asset.load(.isReadable) {
            rows.append(MediaInfoRow(id: "isReadable", label: L10n.string("Readable"), value: yesNo(isReadable)))
        }
        if let isExportable = try? await asset.load(.isExportable) {
            rows.append(MediaInfoRow(id: "isExportable", label: L10n.string("Exportable"), value: yesNo(isExportable)))
        }
        if let isComposable = try? await asset.load(.isComposable) {
            rows.append(MediaInfoRow(id: "isComposable", label: L10n.string("Composable"), value: yesNo(isComposable)))
        }
        if let hasProtectedContent = try? await asset.load(.hasProtectedContent) {
            rows.append(MediaInfoRow(
                id: "protected",
                label: L10n.string("Protected Content"),
                value: yesNo(hasProtectedContent)
            ))
        }
        if let containsFragments = try? await asset.load(.containsFragments) {
            rows.append(MediaInfoRow(
                id: "fragments",
                label: L10n.string("Contains Fragments"),
                value: yesNo(containsFragments)
            ))
        }
        if let preciseTiming = try? await asset.load(.providesPreciseDurationAndTiming) {
            rows.append(MediaInfoRow(
                id: "preciseTiming",
                label: L10n.string("Precise Timing"),
                value: yesNo(preciseTiming)
            ))
        }
        if let preferredRate = try? await asset.load(.preferredRate), preferredRate > 0 {
            rows.append(MediaInfoRow(
                id: "preferredRate",
                label: L10n.string("Preferred Rate"),
                value: MediaInfoTextFormatter.compactDecimal(Double(preferredRate))
            ))
        }
        if let preferredVolume = try? await asset.load(.preferredVolume), preferredVolume >= 0 {
            rows.append(MediaInfoRow(
                id: "preferredVolume",
                label: L10n.string("Preferred Volume"),
                value: MediaInfoTextFormatter.compactDecimal(Double(preferredVolume))
            ))
        }

        return rows
    }

    private static func metadataSections(for asset: AVURLAsset) async throws -> [MediaInfoSection] {
        var sections: [MediaInfoSection] = []
        let commonMetadata = try await asset.load(.metadata)
        if commonMetadata.isEmpty == false {
            sections.append(MediaInfoSection(
                id: "metadata-common",
                title: L10n.string("Common Metadata"),
                rows: await metadataRows(for: commonMetadata, idPrefix: "common")
            ))
        }

        let formats = try await asset.load(.availableMetadataFormats)
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            guard items.isEmpty == false else { continue }
            sections.append(MediaInfoSection(
                id: "metadata-\(format.rawValue)",
                title: metadataFormatTitle(format),
                rows: await metadataRows(for: items, idPrefix: format.rawValue)
            ))
        }

        if sections.isEmpty {
            sections.append(MediaInfoSection(
                id: "metadata-empty",
                title: L10n.string("Embedded Metadata"),
                rows: [MediaInfoRow(
                    id: "metadata-empty-row",
                    label: L10n.string("Metadata"),
                    value: L10n.string("No embedded metadata")
                )]
            ))
        }

        return sections
    }

    private static func metadataRows(for items: [AVMetadataItem], idPrefix: String) async -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []

        for (index, item) in items.enumerated() {
            let label = metadataLabel(for: item, fallback: "\(L10n.string("Item")) \(index + 1)")
            var details: [String] = []

            details.append(await metadataValue(for: item))
            appendDetail(L10n.string("Identifier"), item.identifier?.rawValue, to: &details)
            appendDetail(L10n.string("Common Key"), item.commonKey?.rawValue, to: &details)
            appendDetail(L10n.string("Key Space"), item.keySpace?.rawValue, to: &details)
            appendDetail(L10n.string("Key"), displayValue(item.key), to: &details)
            appendDetail(L10n.string("Data Type"), item.dataType, to: &details)
            appendDetail(L10n.string("Language"), item.extendedLanguageTag ?? item.locale?.identifier, to: &details)

            if item.time.isValid && item.time.seconds.isFinite {
                appendDetail(L10n.string("Time"), item.time.seconds.mediaTime, to: &details)
            }
            if item.duration.isValid && item.duration.seconds.isFinite && item.duration.seconds > 0 {
                appendDetail(L10n.string("Duration"), item.duration.seconds.mediaTime, to: &details)
            }
            if let extraAttributes = try? await item.load(.extraAttributes), extraAttributes.isEmpty == false {
                appendDetail(L10n.string("Extra Attributes"), displayValue(extraAttributes), to: &details)
            }

            rows.append(MediaInfoRow(
                id: "\(idPrefix)-\(index)",
                label: label,
                value: details.filter { $0.isEmpty == false }.joined(separator: "\n")
            ))
        }

        return rows
    }

}

extension MediaInfoInspector {
    private static func trackSections(for asset: AVURLAsset) async throws -> [MediaInfoSection] {
        let tracks = try await asset.load(.tracks)

        return await tracks.enumerated().asyncMap { index, track in
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

            let title = L10n.format("Track %d - %@", index + 1, track.mediaType.rawValue)
            return MediaInfoSection(id: "track-\(index)", title: title, rows: rows)
        }
    }

    private static func formatDescriptionRows(_ descriptions: [CMFormatDescription]) -> [MediaInfoRow] {
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
                rows.append(MediaInfoRow(
                    id: "format-\(index)-sampleRate",
                    label: L10n.format("Format %d Sample Rate", index + 1),
                    value: "\(MediaInfoTextFormatter.compactDecimal(streamDescription.mSampleRate)) Hz"
                ))
                rows.append(MediaInfoRow(
                    id: "format-\(index)-channels",
                    label: L10n.format("Format %d Channels", index + 1),
                    value: String(streamDescription.mChannelsPerFrame)
                ))
                if streamDescription.mBitsPerChannel > 0 {
                    rows.append(MediaInfoRow(
                        id: "format-\(index)-bits",
                        label: L10n.format("Format %d Bits per Channel", index + 1),
                        value: String(streamDescription.mBitsPerChannel)
                    ))
                }
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

    private static func metadataLabel(for item: AVMetadataItem, fallback: String) -> String {
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

    private static func metadataValue(for item: AVMetadataItem) async -> String {
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

    private static func metadataFormatTitle(_ format: AVMetadataFormat) -> String {
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

    private static func appendDetail(_ label: String, _ value: String?, to details: inout [String]) {
        guard let value, value.isEmpty == false else { return }
        details.append("\(label): \(value)")
    }

    private static func displayValue(_ value: Any?) -> String? {
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
            return dictionary.keys.sorted().compactMap { key in
                guard let value = displayValue(dictionary[key]) else { return nil }
                return "\(key): \(value)"
            }.joined(separator: "\n")
        case let dictionary as NSDictionary:
            return dictionary.allKeys
                .map { String(describing: $0) }
                .sorted()
                .compactMap { key in
                    guard let value = displayValue(dictionary[key]) else { return nil }
                    return "\(key): \(value)"
                }
                .joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
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

    private static func yesNo(_ value: Bool) -> String {
        value ? L10n.string("Yes") : L10n.string("No")
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}

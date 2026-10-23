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

        let attributes = try? await FileSystemWorkQueue.runCancellable(qos: .userInitiated) {
            FileAttributes(url: url)
        }
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
        for item: MediaInfoItemSnapshot, url: URL, attributes: FileAttributes?
    ) -> [MediaInfoRow] {
        let byteCount = attributes?.byteCount

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
        if let type = attributes?.contentType {
            rows.append(MediaInfoRow(id: "contentType", label: L10n.string("Content Type"), value: type.identifier))
        }
        if let creationDate = attributes?.creationDate {
            rows.append(MediaInfoRow(
                id: "created",
                label: L10n.string("Created"),
                value: creationDate.formatted(date: .numeric, time: .shortened)
            ))
        }
        if let modifiedDate = attributes?.contentModificationDate {
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

        rows.append(contentsOf: await assetCapabilityRows(for: asset))
        return rows
    }

    private static func assetCapabilityRows(for asset: AVURLAsset) async -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 {
            rows.append(MediaInfoRow(
                id: "assetDuration",
                label: L10n.string("Asset Duration"),
                value: duration.mediaTime
            ))
        }
        rows.append(contentsOf: await assetPropertyRows(for: asset))
        return rows
    }

    private static func assetPropertyRows(for asset: AVURLAsset) async -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []
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

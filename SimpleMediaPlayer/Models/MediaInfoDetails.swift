import Foundation

struct MediaInfoDetails: Equatable, Sendable {
    var fileRows: [MediaInfoRow]
    var summaryRows: [MediaInfoRow]
    var sections: [MediaInfoSection]
    var errorMessage: String?

    static let empty = MediaInfoDetails(fileRows: [], summaryRows: [], sections: [], errorMessage: nil)
}

struct MediaInfoRow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String

    init(id: String? = nil, label: String, value: String) {
        self.id = id ?? "\(label):\(value)"
        self.label = label
        self.value = value
    }
}

struct MediaInfoSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let rows: [MediaInfoRow]

    init(id: String? = nil, title: String, rows: [MediaInfoRow]) {
        self.id = id ?? title
        self.title = title
        self.rows = rows
    }
}

struct MediaInfoItemSnapshot: Sendable {
    let title: String
    let displayArtist: String
    let displayAlbum: String
    let displayGenre: String
    let year: String?
    let trackNumber: String?
    let comment: String?
    let albumArtist: String?
    let composer: String?
    let discNumber: String?
    let isCompilation: Bool
    let duration: TimeInterval
    let isVideo: Bool
    let addedAt: Date
    let fileName: String

    @MainActor
    init(item: MediaItem) {
        title = item.title
        displayArtist = item.displayArtist
        displayAlbum = item.displayAlbum
        displayGenre = item.displayGenre
        year = item.year
        trackNumber = item.trackNumber
        comment = item.comment
        albumArtist = item.albumArtist
        composer = item.composer
        discNumber = item.discNumber
        isCompilation = item.isCompilation
        duration = item.duration
        isVideo = item.isVideo
        addedAt = item.addedAt
        fileName = item.fileName
    }
}

enum MediaInfoTextFormatter {
    static func fileSize(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func compactDecimal(_ value: Double, maximumFractionDigits: Int = 2) -> String {
        guard value.isFinite else { return "" }
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
